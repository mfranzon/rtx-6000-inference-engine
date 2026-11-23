#!/usr/bin/env bash
# Download the pinned Inkling 2 Mini NInfer artifact once, verify size + sha256, then mark it verified
# so later starts skip the 16.5 GB hash.
set -euo pipefail
repo=WaveCut/Inkling-2-Mini-UD-IQ4_XS-NInfer-v3
rev=50d6ad60cfcd170633ead778e3a09958fc1e7887
file=Inkling-2-Mini-UD-IQ4_XS-ninfer-v3.ninfer
size=16494910976
sha=a4a1bbfbdc1150cecc9df2bc12ae87c076330bff81579e243e7875115329bb54

dir=/models/inkling2; dst=$dir/$file; mark=$dir/.verified-$rev
mkdir -p "$dir"
if [[ -f $mark && -f $dst && $(stat -c %s "$dst") == "$size" ]]; then
  echo "model present and verified: $dst"; exit 0
fi
if [[ ! -f $dst || $(stat -c %s "$dst") != "$size" ]]; then
  echo "downloading $repo@${rev:0:8} ($((size / 1024**3)) GiB) to $dir ..."
  auth=(); [[ -n ${HF_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  # -C - resumes an interrupted download; retries cover HF CDN stalls.
  curl -fL --retry 20 --retry-all-errors --retry-delay 5 -C - "${auth[@]}" \
    -o "$dst.part" "https://huggingface.co/$repo/resolve/$rev/$file"
  [[ $(stat -c %s "$dst.part") == "$size" ]] || { echo "size mismatch" >&2; exit 1; }
  mv "$dst.part" "$dst"
fi
echo "verifying sha256 (once, ~1 min) ..."
echo "$sha  $dst" | sha256sum -c -
touch "$mark"
