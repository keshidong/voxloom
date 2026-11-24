"""Load the two separators and their shared CAM++ speaker matcher."""

from pathlib import Path

import numpy as np

from separate import SAMPLE_RATE, TargetSpeaker


def load_separator(assets, model, threads, backend):
    if model == "mossformer2" and backend == "accelerated":
        import coremltools as ct

        network = ct.models.MLModel(str(assets / "MossFormer2_SS_16K.mlpackage"),
                                   compute_units=ct.ComputeUnit.CPU_AND_GPU)
        name = network.get_spec().description.input[0].name

        def separate(audio):
            padded = np.pad(audio, (0, 32776 - len(audio)))
            return network.predict({name: padded[None, :]})["voices"][0, :, :len(audio)]

        return separate

    if model == "mossformer2":
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        session = ort.InferenceSession(str(assets / "mossformer2.onnx"), options,
                                       providers=["CPUExecutionProvider"])
        name = session.get_inputs()[0].name

        def separate(audio):
            # The exported attention groups require 256 steps of the stride-8 encoder.
            size = ((len(audio) - 8 + 2047) // 2048) * 2048 + 8
            padded = np.pad(audio, (0, size - len(audio)))
            tracks = session.run(None, {name: padded[None, :]})[0].squeeze(0)
            return (tracks if tracks.shape[0] == 2 else tracks.T)[:, :len(audio)]

        return separate

    if model == "sepformer":
        import torch
        from speechbrain.inference.separation import SepformerSeparation

        torch.set_num_threads(threads)
        weights = assets / "sepformer"
        device = "mps" if backend == "accelerated" else "cpu"
        separator = SepformerSeparation.from_hparams(source=str(weights), savedir=str(weights),
                                                       run_opts={"device": device})

        def separate(audio):
            with torch.inference_mode():
                return separator.separate_batch(torch.from_numpy(audio[None, :]))[0].T.cpu().numpy()

        return separate

    raise ValueError(f"Unknown separator {model}")


def load_matcher(assets: Path, model: str, threads: int, backend: str = "cpu"):
    if model == "voxlock":
        from voxlock_model import VoxLockModel
        return VoxLockModel(assets, threads)

    return TargetSpeaker(load_separator(assets, model, threads, backend),
                         load_embedding(assets / "campplus.onnx", threads))


def load_embedding(weights, threads):
    import sherpa_onnx

    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=str(weights), num_threads=threads, provider="cpu"))

    def embedding(audio):
        stream = extractor.create_stream()
        stream.accept_waveform(SAMPLE_RATE, np.ascontiguousarray(audio, dtype=np.float32))
        stream.input_finished()
        if not extractor.is_ready(stream):
            return np.zeros(extractor.dim, dtype=np.float32)
        result = np.asarray(extractor.compute(stream), dtype=np.float32)
        return result / max(float(np.linalg.norm(result)), 1e-8)

    return embedding
