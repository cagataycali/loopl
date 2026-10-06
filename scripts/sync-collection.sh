#!/usr/bin/env bash
# Refresh the bundled snapshot of the loopl Hugging Face collection (App/Resources/collection.json) so a first
# launch offline — or an anonymous user while the collection is still private — lists the loopl models.
#   scripts/sync-collection.sh            # uses $HF_TOKEN or ~/.cache/huggingface/token for a private collection
# Slug: Sources/Loopl/HubCollection.swift (LooplCollection.slug) — the one place it lives.
set -euo pipefail
cd "$(dirname "$0")/.."
SLUG=$(sed -n 's/.*public static let slug = "\([^"]*\)".*/\1/p' Sources/Loopl/HubCollection.swift)
[ -n "$SLUG" ] || { echo "slug not found in Sources/Loopl/HubCollection.swift" >&2; exit 1; }
TOKEN="${HF_TOKEN:-$(cat ~/.cache/huggingface/token 2>/dev/null || true)}"
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
TMP=$(mktemp -d)
curl -fsS "${AUTH[@]}" "https://huggingface.co/api/collections/$SLUG" -o "$TMP/collection.json"
AUTHORS=$(python3 -c "import json;print('\n'.join(sorted({i['id'].split('/')[0] for i in json.load(open('$TMP/collection.json'))['items'] if i.get('type')=='model'})))")
: > "$TMP/models.json.parts"
for a in $AUTHORS; do
  curl -fsS "${AUTH[@]}" "https://huggingface.co/api/models?author=$a&limit=500&sort=lastModified&direction=-1&expand[]=config&expand[]=safetensors&expand[]=gguf&expand[]=gated&expand[]=pipeline_tag&expand[]=lastModified&expand[]=likes&expand[]=downloads&expand[]=private&expand[]=library_name&expand[]=tags&expand[]=siblings" >> "$TMP/models.json.parts"; echo >> "$TMP/models.json.parts"
done
python3 - "$TMP" <<'PY'
import json, sys, datetime
tmp = sys.argv[1]
coll = json.load(open(f"{tmp}/collection.json"))
ids = {i["id"] for i in coll["items"] if i.get("type") == "model"}
rows = []
for line in open(f"{tmp}/models.json.parts"):
    line = line.strip()
    if line: rows += [r for r in json.loads(line) if r["id"] in ids]
# Only what the app renders — keep the file small and diff-friendly.
keep = ["id","private","gated","pipeline_tag","lastModified","likes","downloads","library_name","tags","config","safetensors","gguf","siblings"]
rows = [{k: r[k] for k in keep if k in r} for r in rows]
items = [{k: v for k, v in i.items() if k not in ("authorData","_id","isLikedByUser","widgetOutputUrls","availableInferenceProviders")} for i in coll["items"]]
coll = {k: v for k, v in coll.items() if k not in ("owner","isUpvotedByUser")}
coll["items"] = items
out = {"saved": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "collection": coll, "models": rows}
json.dump(out, open("App/Resources/collection.json", "w"), indent=1, ensure_ascii=False)
print(f"App/Resources/collection.json: {coll['title']} · {len(items)} items · {len(rows)} hub rows · private={coll.get('private')}")
PY
rm -rf "$TMP"
