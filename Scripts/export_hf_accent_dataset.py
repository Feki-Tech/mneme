#!/usr/bin/env python3
"""Export a Hugging Face speech dataset to audio files and a Mneme evaluation manifest.

Default columns match EdAcc, the Edinburgh International Accents of English Corpus
(edinburghcstr/edacc: conversational English from speakers of 40+ accents, CC BY-SA 4.0).

    python3 -m pip install datasets soundfile
    python3 Scripts/export_hf_accent_dataset.py edinburghcstr/edacc --split test \
        --region-column l1 --max-per-accent 25 --out eval/edacc
    mneme eval eval/edacc/manifest.jsonl

Other datasets work too; pass their column names (the script lists the available columns if one is missing).
Audio is written as provided when it is already in a format Mneme reads, otherwise as 16-bit WAV.
"""
import argparse
import collections
import io
import json
import os
import sys

SUPPORTED = {".wav", ".flac", ".mp3", ".m4a", ".aiff", ".aif", ".caf"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dataset", help="Hugging Face dataset name, for example edinburghcstr/edacc")
    parser.add_argument("--config", default=None, help="Dataset configuration, if any")
    parser.add_argument("--split", default="test")
    parser.add_argument("--out", required=True, help="Output folder")
    parser.add_argument("--audio-column", default="audio")
    parser.add_argument("--text-column", default="text")
    parser.add_argument("--accent-column", default="accent")
    parser.add_argument("--speaker-column", default="speaker")
    parser.add_argument("--region-column", default=None)
    parser.add_argument("--language", default="en", help="Language of the references (ISO 639-1)")
    parser.add_argument("--max-per-accent", type=int, default=0, help="0 means no limit")
    parser.add_argument("--min-words", type=int, default=3, help="Skip shorter references")
    args = parser.parse_args()

    try:
        from datasets import Audio, load_dataset
        import soundfile
    except ImportError:
        print("Install the dependencies first: python3 -m pip install datasets soundfile", file=sys.stderr)
        return 1

    dataset = load_dataset(args.dataset, args.config, split=args.split)
    missing = [c for c in (args.audio_column, args.text_column) if c not in dataset.column_names]
    if missing:
        print(f"Missing columns {missing}. Available: {dataset.column_names}", file=sys.stderr)
        return 1
    # Raw bytes: avoids depending on a particular audio decoding backend.
    dataset = dataset.cast_column(args.audio_column, Audio(decode=False))

    audio_dir = os.path.join(args.out, "audio")
    os.makedirs(audio_dir, exist_ok=True)
    per_accent = collections.Counter()
    written = 0
    with open(os.path.join(args.out, "manifest.jsonl"), "w", encoding="utf-8") as manifest:
        for index, row in enumerate(dataset):
            text = " ".join(str(row.get(args.text_column) or "").split())
            if len(text.split()) < args.min_words:
                continue
            accent = str(row.get(args.accent_column) or "unknown").strip() or "unknown"
            if args.max_per_accent and per_accent[accent] >= args.max_per_accent:
                continue
            audio = row[args.audio_column] or {}
            data, source_path = audio.get("bytes"), audio.get("path") or ""
            if data is None and source_path and os.path.exists(source_path):
                with open(source_path, "rb") as handle:
                    data = handle.read()
            if not data:
                continue
            extension = os.path.splitext(source_path)[1].lower()
            name = f"{index:06d}"
            if extension in SUPPORTED:
                filename = name + extension
                with open(os.path.join(audio_dir, filename), "wb") as handle:
                    handle.write(data)
            else:
                samples, rate = soundfile.read(io.BytesIO(data))
                filename = name + ".wav"
                soundfile.write(os.path.join(audio_dir, filename), samples, rate, subtype="PCM_16")
            item = {"id": name, "audio": f"audio/{filename}", "text": text, "language": args.language, "accent": accent}
            if args.speaker_column and row.get(args.speaker_column) is not None:
                item["speaker"] = str(row[args.speaker_column])
            if args.region_column and row.get(args.region_column) is not None:
                item["region"] = str(row[args.region_column])
            manifest.write(json.dumps(item, ensure_ascii=False, sort_keys=True) + "\n")
            per_accent[accent] += 1
            written += 1

    print(f"Wrote {written} items covering {len(per_accent)} accents to {args.out}/manifest.jsonl")
    return 0


if __name__ == "__main__":
    sys.exit(main())
