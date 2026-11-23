#!/bin/bash
set -euo pipefail

test "$(uname -m)" = "$ARQUITETURA"
trabalho=$(mktemp -d "$RUNNER_TEMP/gzeroos.XXXXXX")
kit="$trabalho/extraido/GzeroOS-Mac-Kit"
usuario="$trabalho/usuario"
raiz="$trabalho/disco"
montado="$trabalho/montado"
resultado="$RUNNER_TEMP/$DISCO"
mkdir -p "$trabalho/extraido" "$usuario" "$raiz" "$montado" "$trabalho/ensaio" "$trabalho/aplicativos"
ditto -x -k "$RUNNER_TEMP/kit.zip" "$trabalho/extraido"
test "$(cat "$kit/version.txt")" = 0.8.1

# O instalador compila o auxiliar nativo e valida o SHA-256 oficial do Electron.
# Os logs da instalação privada nunca integram o disco ou a saída pública.
if ! env HOME="$usuario" "$kit/Instalar-GzeroOS.command" --sem-abrir > "$trabalho/instalar.log" 2>&1; then
  echo 'Falha na instalação ou na assinatura do aplicativo.' >&2
  exit 1
fi
ditto "$usuario/Applications/GzeroOS.app" "$raiz/GzeroOS.app"
ditto "$kit/Extensao-MAIA" "$raiz/Extensao-MAIA"
ditto "$kit/Licencas" "$raiz/Licencas"
for doc in GUIA-MACOS.md GUIA-GZEROOS.md GOOGLE-CALENDAR.md PRIVACIDADE.md TERCEIROS.txt LEIA-ME.txt; do
  test -s "$kit/Guias/$doc"
  cp "$kit/Guias/$doc" "$raiz/$doc"
done
ln -s /Applications "$raiz/Applications"
test -s "$raiz/Extensao-MAIA/manifest.json"
find "$raiz" -type f \( -name '*.swift' -o -name '*.map' -o -name 'verificar-ui.mjs' -o -name '*.command' \) -print > "$trabalho/reservados.txt"
if test -s "$trabalho/reservados.txt"; then
  echo 'O disco contém um arquivo reservado à montagem.' >&2
  exit 1
fi
hdiutil create -quiet -volname GzeroOS -format UDZO -fs HFS+ -srcfolder "$raiz" "$resultado"
hdiutil verify -quiet "$resultado"
hdiutil attach -readonly -nobrowse -mountpoint "$montado" "$resultado" >/dev/null
trap 'hdiutil detach -quiet "$montado" || true' EXIT
test "$(readlink "$montado/Applications")" = /Applications
test -s "$montado/Extensao-MAIA/manifest.json"

# Simula arrastar o app do disco para uma pasta gravável e depois abri-lo.
app="$trabalho/aplicativos/GzeroOS.app"
ditto "$montado/GzeroOS.app" "$app"
plist="$app/Contents/Info.plist"
executavel="$app/Contents/MacOS/GzeroOS"
recursos="$app/Contents/Resources"
auxiliar="$recursos/native/maia-macos"
test -x "$executavel" && test -x "$auxiliar" && test -s "$recursos/gzeroos-mcp.cjs"
codesign --verify --deep --strict "$app"
lipo "$executavel" -verify_arch "$ARQUITETURA"
lipo "$auxiliar" -verify_arch "$ARQUITETURA"
python3 - "$plist" "$recursos/app/package.json" <<'PY'
import json, plistlib, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.load(f)
assert p['CFBundleIdentifier'] == 'com.gravidadezero.maia'
assert p['CFBundleExecutable'] == 'GzeroOS'
assert p['CFBundleShortVersionString'] == p['CFBundleVersion'] == '0.8.1'
assert any('gzeroos' in t.get('CFBundleURLSchemes', []) for t in p['CFBundleURLTypes'])
with open(sys.argv[2], encoding='utf-8') as f:
    assert json.load(f)['version'] == '0.8.1'
PY

"$auxiliar" --self-test > "$trabalho/auxiliar.json"
python3 - "$executavel" "$recursos/gzeroos-mcp.cjs" <<'PY'
import json, os, subprocess, sys
msgs = [
  {'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'verificacao','version':'1'}}},
  {'jsonrpc':'2.0','method':'notifications/initialized'},
  {'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}},
]
r = subprocess.run(sys.argv[1:], env={**os.environ, 'ELECTRON_RUN_AS_NODE':'1'}, input=''.join(json.dumps(m)+'\n' for m in msgs), capture_output=True, text=True, timeout=30, check=True)
replies = {m['id']:m['result'] for m in map(json.loads,r.stdout.splitlines())}
assert replies[1]['serverInfo']['name'] == 'gzeroos'
assert {'buscar','ler_pagina'} <= {t['name'] for t in replies[2]['tools']}
PY
cd "$trabalho/ensaio"
npm install --ignore-scripts --no-save --no-audit --no-fund --loglevel=error playwright-core@1.63.0
cp "$kit/Ensaio/verificar-ui.mjs" ./verificar-ui.mjs
if ! env MAIA_EXECUTABLE="$executavel" node verificar-ui.mjs > "$trabalho/ui.log" 2>&1; then
  echo 'O aplicativo instalado a partir do disco não passou pela verificação da interface.' >&2
  exit 1
fi
printf 'Aplicativo, auxiliar, interface e MCP da versão 0.8.1 verificados no Mac %s.\n' "$ARQUITETURA"
