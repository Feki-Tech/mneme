#!/bin/bash
# Synthesises a code-switching test set with the voices installed on this Mac: recordings that move between
# languages from one sentence to the next, and sentences that embed words from another language.
#
#   bash Scripts/make-codeswitch-samples.sh [output-folder]
#   mneme languages set fr en de ar --archive <scratch>
#   mneme eval eval/cs/manifest.jsonl --language-mode detect --use-profile --archive <scratch> --language-strategy sentence
#
# Each switching item joins sentences spoken by different voices with a short pause. Synthetic speech is
# clean: treat the results as a check of language handling, not of accent robustness.
set -euo pipefail
OUT="${1:-eval/cs}"
mkdir -p "$OUT/parts"
MANIFEST="$OUT/manifest.jsonl"
: > "$MANIFEST"

NOVELTY="^(Albert|Bad News|Bahh|Bells|Boing|Bubbles|Cellos|Good News|Jester|Organ|Superstar|Trinoids|Whisper|Wobble|Zarvox)"
voice_for() {
  # The first installed voice of the first locale that has one.
  local locale name
  for locale in "$@"; do
    name="$(say -v '?' | grep -E "[[:space:]]${locale}[[:space:]]" | grep -vE "$NOVELTY" | head -n 1 \
      | sed -E "s/[[:space:]]+${locale}[[:space:]].*$//" | sed -E 's/[[:space:]]+$//')"
    if [ -n "$name" ]; then
      echo "$name"
      return
    fi
  done
}

VOICE_fr="$(voice_for fr_FR fr_CA)"
VOICE_en="$(voice_for en_US en_GB en_AU)"
VOICE_de="$(voice_for de_DE de_AT de_CH)"
VOICE_ar="$(voice_for ar_001 ar_SA)"
echo "Voices: fr=${VOICE_fr:-none} en=${VOICE_en:-none} de=${VOICE_de:-none} ar=${VOICE_ar:-none}"

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

join_parts() {
  python3 - "$@" <<'PY'
import sys, wave
out_path, parts = sys.argv[1], sys.argv[2:]
silence = lambda seconds: b"\x00\x00" * int(16000 * seconds)
with wave.open(out_path, "wb") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(16000)
    out.writeframes(silence(0.2))
    for index, part in enumerate(parts):
        with wave.open(part, "rb") as source:
            if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
                raise SystemExit(f"unexpected format in {part}")
            out.writeframes(source.readframes(source.getnframes()))
        if index < len(parts) - 1:
            out.writeframes(silence(0.7))
    out.writeframes(silence(0.2))
PY
}

# id|label|kind|language:sentence|language:sentence...   (no digits: "5" versus "five" is not a language error)
ITEMS=(
  "fr-en-1|fr+en|between sentences|fr:Ce matin, j'ai relu tout le chapitre avant le déjeuner.|en:Then I sent the draft to my editor in London."
  "en-fr-1|en+fr|between sentences|en:I finally fixed the bug in the gateway firmware.|fr:Maintenant, je dois écrire la documentation pour l'équipe."
  "de-en-1|de+en|between sentences|de:Heute Abend treffe ich meine Freunde am Bahnhof.|en:We are going to watch the football match together."
  "en-de-1|en+de|between sentences|en:The meeting with the client went really well.|de:Morgen schicke ich ihnen das Angebot per E-Mail."
  "fr-de-1|fr+de|between sentences|fr:Je dois appeler ma sœur pour son anniversaire.|de:Danach fahre ich mit dem Zug nach Berlin."
  "de-fr-1|de+fr|between sentences|de:Ich habe heute den ganzen Tag programmiert.|fr:Ce soir, je vais me reposer et lire un bon livre."
  "ar-fr-1|ar+fr|between sentences|ar:صباح الخير، عندي اليوم اجتماع مهم في العمل.|fr:Ensuite, je vais faire les courses au marché."
  "fr-ar-1|fr+ar|between sentences|fr:Je pense souvent à la maison de mes grands-parents.|ar:كانت الحديقة مليئة بأشجار الليمون والزيتون."
  "en-fr-en-1|en+fr|between sentences|en:I need to buy some bread on the way home.|fr:Et surtout, n'oublie pas d'appeler le médecin demain matin.|en:Also, the package should arrive on Thursday."
  "fr-en-fr-1|fr+en|between sentences|fr:Nous avons présenté le prototype aux investisseurs.|en:They asked about the energy consumption of the sensors.|fr:Je vais préparer une réponse détaillée pour lundi."
  "de-en-de-1|de+en|between sentences|de:Das Wetter in Hamburg war heute furchtbar.|en:I forgot my umbrella at the office again.|de:Morgen nehme ich lieber den Bus."
  "intra-fr-1|fr with English words|within a sentence|fr:Demain, j'ai un meeting avec le client pour la sprint review."
  "intra-fr-2|fr with English words|within a sentence|fr:Le deadline du projet, c'est vendredi, donc on fait un quick fix."
  "intra-de-1|de with English words|within a sentence|de:Ich habe heute ein Meeting mit dem Team wegen dem neuen Release."
)

count=0
for entry in "${ITEMS[@]}"; do
  IFS='|' read -r -a fields <<< "$entry"
  id="${fields[0]}"; label="${fields[1]}"; kind="${fields[2]}"
  parts=(); texts=(); speakers=(); languages=(); first_language=""; missing=0
  for spec in "${fields[@]:3}"; do
    language="${spec%%:*}"; sentence="${spec#*:}"
    case "$language" in
      fr) voice="$VOICE_fr" ;;
      en) voice="$VOICE_en" ;;
      de) voice="$VOICE_de" ;;
      ar) voice="$VOICE_ar" ;;
      *) voice="" ;;
    esac
    if [ -z "$voice" ]; then
      missing=1
      break
    fi
    part="$OUT/parts/$id-${#parts[@]}.wav"
    say -v "$voice" --file-format=WAVE --data-format=LEI16@16000 -o "$part" "$sentence"
    parts+=("$part"); texts+=("$sentence"); speakers+=("$voice")
    [ -z "$first_language" ] && first_language="$language"
    # The expected sequence of languages, consecutive repeats merged.
    if [ ${#languages[@]} -eq 0 ] || [ "${languages[${#languages[@]}-1]}" != "$language" ]; then
      languages+=("$language")
    fi
  done
  if [ $missing -eq 1 ]; then
    echo "  skipped $id: no voice for one of its languages"
    continue
  fi
  join_parts "$OUT/$id.wav" "${parts[@]}"
  reference="${texts[*]}"
  speaker="$(IFS=+; echo "${speakers[*]}")"
  sequence="$(printf '"%s",' "${languages[@]}")"
  printf '{"accent":"%s","audio":"%s","id":"%s","language":"%s","languages":[%s],"region":"%s","speaker":"%s","text":"%s"}\n' \
    "$(json_escape "$label")" "$id.wav" "$id" "$first_language" "${sequence%,}" "$(json_escape "$kind")" \
    "$(json_escape "$speaker")" "$(json_escape "$reference")" >> "$MANIFEST"
  count=$((count + 1))
done
echo "Wrote $count items to $MANIFEST"
