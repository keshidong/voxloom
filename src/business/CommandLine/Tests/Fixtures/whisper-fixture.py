#!/usr/bin/python3
"""Strict synthetic external-engine fixture. Never a real recognition test."""
import argparse
import json
import os
import time
import wave

parser = argparse.ArgumentParser()
for option in ['model', 'file', 'language', 'threads', 'output-file']:
    parser.add_argument('--' + option, required=True)
for option in ['output-json', 'no-prints', 'no-gpu']:
    parser.add_argument('--' + option, action='store_true')
parser.add_argument('--prompt')
args = parser.parse_args()
with wave.open(args.file, 'rb') as audio:
    assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2)
with open(args.model, encoding='utf-8') as source:
    model = json.load(source)
if model.get('hold'):
    with open(model['marker'], 'w') as marker:
        json.dump({'pid': os.getpid(), 'job': os.path.dirname(args.output_file)}, marker)
    time.sleep(60)
if model.get('exit'):
    raise SystemExit(model['exit'])
with open(args.output_file + '.json', 'w', encoding='utf-8') as target:
    json.dump({'model': {'multilingual': True}, 'params': {'translate': False},
               'result': {'language': args.language if args.language != 'auto' else 'zh'},
               'transcription': [{'text': model.get('text', '中文 English')}]}, target)
