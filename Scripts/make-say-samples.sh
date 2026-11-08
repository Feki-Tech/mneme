#!/bin/bash
# Synthesises a small accent smoke test with the voices installed on this Mac and writes a manifest.
#
#   ./Scripts/make-say-samples.sh [output-folder] [--multilingual]
#   mneme eval eval/say/manifest.jsonl
#
# English voices cover several regional accents (en_US, en_GB, en_AU, en_IE, en_IN, en_ZA, Scottish...).
# With --multilingual, one voice per other installed language reads a sentence in that language, which
# is useful with `mneme eval --language-mode detect`. Synthetic voices are clean and regular: treat the
# results as a smoke test, not as a measure of real accented speech. More voices can be added in
# System Settings > Accessibility > Spoken Content > System Voice > Manage Voices.
set -euo pipefail

OUT="eval/say"
MULTILINGUAL=0
for argument in "$@"; do
  case "$argument" in
    --multilingual) MULTILINGUAL=1 ;;
    *) OUT="$argument" ;;
  esac
done
mkdir -p "$OUT"
MANIFEST="$OUT/manifest.jsonl"
: > "$MANIFEST"

# No numbers: "42" versus "forty two" would count as errors that have nothing to do with accents.
ENGLISH=(
  "Please call Amira and ask her to bring the blue notebooks from the library on Friday."
  "The train to Manchester leaves early in the morning, so we should meet at the station before sunrise."
  "My grandmother grew tomatoes, peppers and fresh mint in a small garden behind the house."
  "We need more chairs, a few tables and a projector for the workshop next Tuesday."
)

sentence_for() {
  case "$1" in
    fr) echo "Bonjour, je m'appelle Claire et j'habite à Lyon depuis longtemps." ;;
    de) echo "Guten Morgen, ich heiße Jonas und wohne seit Langem in Hamburg." ;;
    es) echo "Buenos días, me llamo Lucía y vivo en Sevilla desde hace mucho tiempo." ;;
    it) echo "Buongiorno, mi chiamo Marco e abito a Torino da molto tempo." ;;
    pt) echo "Bom dia, chamo-me Inês e moro em Lisboa há muito tempo." ;;
    nl) echo "Goedemorgen, ik heet Sanne en ik woon al lang in Utrecht." ;;
    ar) echo "صباح الخير، اسمي ليلى وأسكن في تونس منذ وقت طويل." ;;
    hi) echo "नमस्ते, मेरा नाम अनीता है और मैं बहुत समय से पुणे में रहती हूँ।" ;;
    tr) echo "Günaydın, benim adım Elif ve uzun zamandır İzmir'de yaşıyorum." ;;
    *) echo "" ;;
  esac
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

NOVELTY="Albert|Bad News|Bahh|Bells|Boing|Bubbles|Cellos|Good News|Jester|Organ|Superstar|Trinoids|Whisper|Wobble|Zarvox"
seen_locales=" "
count=0

while IFS= read -r line; do
  description="${line%%#*}"
  description="$(echo "$description" | sed -E 's/[[:space:]]+$//')"
  locale="${description##* }"
  name="$(echo "${description% *}" | sed -E 's/[[:space:]]+$//')"
  [ -z "$name" ] && continue
  echo "$name" | grep -Eq "^($NOVELTY)" && continue
  case "$seen_locales" in *" $locale "*) continue ;; esac
  language="$(echo "$locale" | sed -E 's/[_-].*//' | tr '[:upper:]' '[:lower:]')"

  if [ "$language" = "en" ]; then
    sentences=("${ENGLISH[@]}")
  elif [ $MULTILINGUAL -eq 1 ] && [ -n "$(sentence_for "$language")" ]; then
    sentences=("$(sentence_for "$language")")
  else
    continue
  fi
  seen_locales="$seen_locales$locale "

  slug="$(echo "$locale-$name" | tr -cs '[:alnum:]' '-' | sed -E 's/-+$//')"
  index=0
  for sentence in "${sentences[@]}"; do
    index=$((index + 1))
    file="$slug-$index.aiff"
    if ! say -v "$name" -o "$OUT/$file" "$sentence" 2> /dev/null; then
      echo "  skipped $name ($locale): the voice could not be used"
      continue
    fi
    printf '{"accent":"%s","audio":"%s","id":"%s","language":"%s","speaker":"%s","text":"%s"}\n' \
      "$(json_escape "$locale")" "$(json_escape "$file")" "$(json_escape "$slug-$index")" "$language" \
      "$(json_escape "$name")" "$(json_escape "$sentence")" >> "$MANIFEST"
    count=$((count + 1))
  done
  echo "  $locale: $name"
done < <(say -v '?')

echo "Wrote $count samples to $MANIFEST"
echo "Next: mneme eval $MANIFEST"
