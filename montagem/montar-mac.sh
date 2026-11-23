#!/bin/bash
set -euo pipefail

registro="$RUNNER_TEMP/gzeroos-montagem.log"
fase='preparação'
exec 3>&1 > "$registro" 2>&1
trap 'printf "Falha na fase %s (código %s).\n" "$fase" "$?" >&3' ERR

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

# O ZIP pode vir do Windows. Regrava as mesmas permissões no XML canônico do macOS
# antes de o codesign entregá-las ao leitor AMFI do sistema.
fase='normalização das permissões de assinatura'
entitlements="$kit/native/entitlements.mac.plist"
python3 - "$entitlements" "$trabalho/entitlements.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as original:
    permissoes = plistlib.load(original)
esperadas = {'com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory',
             'com.apple.security.cs.disable-library-validation', 'com.apple.security.device.audio-input'}
assert set(permissoes) == esperadas and all(v is True for v in permissoes.values())
with open(sys.argv[2], 'wb') as canonico:
    plistlib.dump(permissoes, canonico, fmt=plistlib.FMT_XML, sort_keys=False)
PY
plutil -lint "$trabalho/entitlements.plist"
cp "$trabalho/entitlements.plist" "$entitlements"

# O instalador compila o auxiliar nativo e valida o SHA-256 oficial do Electron.
# Os logs da instalação privada nunca integram o disco ou a saída pública.
fase='instalação'
if env HOME="$usuario" /bin/bash "$kit/Instalar-GzeroOS.command" --sem-abrir; then
  :
else
  codigo=$?
  numero=$(awk '/^[1-5]\/5 /{n=substr($0,1,1)} END {print n+0}' "$registro")
  case "$numero" in
    1) fase='1/5 compilação ou autoteste nativo';;
    2) fase='2/5 download ou integridade do Electron';;
    3) fase='3/5 montagem do aplicativo';;
    4) fase='4/5 assinatura e verificação';;
    5) fase='5/5 cópia do aplicativo';;
    *) fase='pré-requisitos da instalação';;
  esac
  printf 'Falha na fase %s (código %s).\n' "$fase" "$codigo" >&3
  exit "$codigo"
fi
fase='preparação do conteúdo do disco'
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
fase='criação e verificação do disco'
hdiutil create -quiet -volname GzeroOS -format UDZO -fs HFS+ -srcfolder "$raiz" "$resultado"
hdiutil verify -quiet "$resultado"
hdiutil attach -readonly -nobrowse -mountpoint "$montado" "$resultado" >/dev/null
trap 'hdiutil detach -quiet "$montado" || true' EXIT
test "$(readlink "$montado/Applications")" = /Applications
test -s "$montado/Extensao-MAIA/manifest.json"

# Simula arrastar o app do disco para uma pasta gravável e depois abri-lo.
fase='verificação da cópia, arquitetura e assinatura'
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

fase='autoteste do auxiliar nativo'
"$auxiliar" --self-test > "$trabalho/auxiliar.json"
fase='inicialização do MCP'
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
fase='preparação do teste de interface'
npm install --ignore-scripts --no-save --no-audit --no-fund --loglevel=error playwright-core@1.63.0
xcrun swiftc "$GITHUB_WORKSPACE/montagem/cursor.swift" -o "$trabalho/cursor"
cp "$GITHUB_WORKSPACE/montagem/cursor.mjs" ./cursor.mjs
python3 - "$kit/Ensaio/verificar-ui.mjs" <<'PY'
from pathlib import Path
import sys
qa = Path(sys.argv[1]).read_text(encoding='utf-8')
entrada = "await page.locator('.pill-hit').hover()"
alvo = "page.getByRole('button', { name: 'Abrir contexto atual', exact: true })"
clique = f'await {alvo}.click()'
assert qa.count(entrada) == 1 and qa.count(clique) == 1
qa = qa.replace(entrada, "await alinharCursor(app, page, page.locator('.pill-hit'))")
qa = qa.replace(clique, f'await alinharCursor(app, page, {alvo})\n  {clique}')
Path('verificar-ui.mjs').write_text("import { alinharCursor } from './cursor.mjs'\n" + qa, encoding='utf-8')
PY
fase='teste de interface'
env MAIA_EXECUTABLE="$executavel" GZEROOS_CURSOR_ENSAIO="$trabalho/cursor" node verificar-ui.mjs
printf 'Aplicativo, auxiliar, interface e MCP da versão 0.8.1 verificados no Mac %s.\n' "$ARQUITETURA" >&3
