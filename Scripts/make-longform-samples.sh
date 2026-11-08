#!/bin/bash
# Synthesises two long recordings (English and French, about two minutes each) for speed measurements:
# long audio shows the steady-state real-time factor, which short clips hide behind per-window overhead.
#   bash Scripts/make-longform-samples.sh [output-folder]
set -euo pipefail
OUT="${1:-eval/long}"
mkdir -p "$OUT"

voice_for() {
  # First installed voice of the locale prefix, ignoring novelty voices.
  say -v '?' | grep -E "[[:space:]]$1[_-]" | grep -vE "^(Albert|Bad News|Bahh|Bells|Boing|Bubbles|Cellos|Good News|Jester|Organ|Superstar|Trinoids|Whisper|Wobble|Zarvox)" \
    | head -n 1 | sed -E 's/[[:space:]]+[a-z]{2}[_-][A-Za-z0-9]+.*$//' | sed -E 's/[[:space:]]+$//'
}

cat > "$OUT/en.txt" <<'TEXT'
This morning I walked along the harbour before the city woke up. The fishing boats were coming back, and the light on the water changed every few minutes, from grey to silver and then to a pale gold. I want to remember this moment, because it reminded me why I started writing in the first place. When I was a child, my grandfather used to take me to the same place on Sunday mornings. He never said much, but he pointed at the birds, the ropes, the old men repairing their nets, and he named everything in three languages, as if each object deserved more than one name. Later, at university, I forgot those mornings for a long time. I was busy with exams, projects and deadlines, and writing felt like a luxury. Now I think the opposite is true. Writing is the only way I have found to slow down and to notice what is happening around me. So here is the plan for the next weeks. Every evening, I will record a short note about one thing I saw, heard or learned during the day. At the end of the month, I will read everything again and choose the ideas that are worth developing into longer chapters. Some of them will be about the sea, some about the people I work with, and some about the strange experience of thinking in several languages at the same time. I also want to call my sister this weekend, finish the presentation for the client on Tuesday, and buy a new notebook, because the old one is almost full.
TEXT

cat > "$OUT/fr.txt" <<'TEXT'
Ce matin, je me suis promené le long du port avant que la ville ne se réveille. Les bateaux de pêche rentraient, et la lumière sur l'eau changeait toutes les quelques minutes, du gris à l'argent, puis à un or très pâle. Je veux me souvenir de ce moment, parce qu'il m'a rappelé pourquoi j'ai commencé à écrire. Quand j'étais enfant, mon grand-père m'emmenait au même endroit le dimanche matin. Il ne parlait pas beaucoup, mais il montrait les oiseaux, les cordes, les vieux pêcheurs qui réparaient leurs filets, et il nommait chaque chose dans trois langues, comme si chaque objet méritait plus d'un nom. Plus tard, à l'université, j'ai oublié ces matins pendant longtemps. J'étais occupé par les examens, les projets et les délais, et l'écriture me semblait être un luxe. Aujourd'hui, je pense que c'est le contraire. Écrire est la seule façon que j'ai trouvée pour ralentir et pour remarquer ce qui se passe autour de moi. Alors voici le plan pour les prochaines semaines. Chaque soir, j'enregistrerai une courte note sur une chose que j'ai vue, entendue ou apprise pendant la journée. À la fin du mois, je relirai tout et je choisirai les idées qui méritent de devenir des chapitres plus longs. Certaines parleront de la mer, d'autres des personnes avec qui je travaille, et d'autres encore de cette étrange expérience de penser dans plusieurs langues en même temps.
TEXT

for language in en fr; do
  voice="$(voice_for "$language")"
  if [ -z "$voice" ]; then
    echo "  no $language voice installed, skipped"
    continue
  fi
  if [ ! -s "$OUT/$language.aiff" ]; then
    say -v "$voice" -o "$OUT/$language.aiff" -f "$OUT/$language.txt"
  fi
  echo "  $language: $voice, $(afinfo "$OUT/$language.aiff" | grep -i 'estimated duration' | sed -E 's/.*: //')"
done
