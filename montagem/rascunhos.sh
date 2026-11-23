#!/bin/bash
set -euo pipefail

test "$GITHUB_REPOSITORY" = 'Artur-Antunes-1/maia-downloads'
test "$GITHUB_REF" = 'refs/heads/montagem/macos-0.8.1'
test "$(git rev-parse HEAD)" = "$GITHUB_SHA"
test "$GH_REPO" = "$GITHUB_REPOSITORY"
jq -e '.versao == "0.8.1" and (.origemId|numbers) > 0 and (.destinoId|numbers) > 0 and .origemId != .destinoId and (.kitSha256|test("^[a-f0-9]{64}$"))' montagem.json >/dev/null
origem=$(jq -r .origemId montagem.json)
destino=$(jq -r .destinoId montagem.json)
hash=$(jq -r .kitSha256 montagem.json)
base="repos/$GH_REPO/releases"
kit=GzeroOS-Mac-Kit-0.8.1.zip

rascunho() {
  gh api "$base/$1" > "$RUNNER_TEMP/registro.json"
  jq -e --arg tag "$2" --arg id "$1" '.draft == true and .tag_name == $tag and (.id|tostring) == $id' "$RUNNER_TEMP/registro.json" >/dev/null
}

case "$1" in
obter)
  rascunho "$destino" v0.8.1
  rascunho "$origem" insumos-macos-0.8.1
  asset=$(jq -er --arg nome "$kit" --arg digest "sha256:$hash" '[.assets[] | select(.name == $nome and .state == "uploaded" and .digest == $digest)] | select(length == 1) | .[0].id' "$RUNNER_TEMP/registro.json")
  gh api --header 'Accept: application/octet-stream' "$base/assets/$asset" > "$RUNNER_TEMP/kit.zip"
  test "$(shasum -a 256 "$RUNNER_TEMP/kit.zip" | awk '{print $1}')" = "$hash"
  ;;
diagnostico)
  case "$ARQUITETURA" in arm64|x86_64) ;; *) exit 1;; esac
  [[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]]
  arquivo="$RUNNER_TEMP/gzeroos-montagem.log"
  test -f "$arquivo" && test ! -L "$arquivo"
  nome="diagnostico-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$ARQUITETURA.log"
  rascunho "$origem" insumos-macos-0.8.1
  curl --fail --silent --show-error --request POST --header "Authorization: Bearer $GH_TOKEN" --header 'Content-Type: text/plain' --data-binary "@$arquivo" \
    "https://uploads.github.com/repos/$GH_REPO/releases/$origem/assets?name=$nome" | \
    jq -e --arg nome "$nome" '.state == "uploaded" and .name == $nome' >/dev/null
  ;;
guardar)
  case "$ARQUITETURA/$DISCO" in arm64/GzeroOS-Mac-AppleSilicon.dmg|x86_64/GzeroOS-Mac-Intel.dmg) ;; *) exit 1;; esac
  arquivo="$RUNNER_TEMP/$DISCO"
  digest="sha256:$(shasum -a 256 "$arquivo" | awk '{print $1}')"
  size=$(stat -f '%z' "$arquivo")
  test "$size" -gt 0
  rascunho "$destino" v0.8.1
  conferir() {
    jq -e --arg nome "$DISCO" --arg digest "$digest" --argjson size "$size" '.name == $nome and .state == "uploaded" and .digest == $digest and .size == $size' >/dev/null
  }
  if jq -e --arg nome "$DISCO" '.assets[] | select(.name == $nome)' "$RUNNER_TEMP/registro.json" > "$RUNNER_TEMP/disco.json"; then
    conferir < "$RUNNER_TEMP/disco.json"
  else
    curl --fail --silent --show-error --request POST --header "Authorization: Bearer $GH_TOKEN" --header 'Content-Type: application/octet-stream' --data-binary "@$arquivo" \
      "https://uploads.github.com/repos/$GH_REPO/releases/$destino/assets?name=$DISCO" | conferir
  fi
  rascunho "$destino" v0.8.1
  printf '%s  %s\n' "$digest" "$DISCO"
  ;;
*) exit 1;;
esac
