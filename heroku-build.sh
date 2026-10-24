#!/usr/bin/env bash
# Compile le site d'Apertis : le serveur et les îlots (WebAssembly).
# Lancé sur Heroku par RustConfig une fois Rust installé par le buildpack emk/rust ;
# fonctionne aussi à la main depuis le dépôt : ./heroku-build.sh
# Le Procfile démarre site/target/release/apertis-site depuis site/ (public/ et pkg/).
set -euo pipefail

# Paquets et ses paquets sont des dépôts privés : Cargo les récupère avec git, qui
# demande les identifiants GitHub à un assistant lisant la config var REPOS_TOKEN
# (le buildpack la transmet dans ENV_DIR). Le jeton n'apparaît dans aucune URL.
if [ -z "${REPOS_TOKEN:-}" ] && [ -n "${ENV_DIR:-}" ] && [ -f "$ENV_DIR/REPOS_TOKEN" ]; then
  REPOS_TOKEN=$(<"$ENV_DIR/REPOS_TOKEN")
fi
if [ -n "${REPOS_TOKEN:-}" ]; then
  export REPOS_TOKEN CARGO_NET_GIT_FETCH_WITH_CLI=true GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=credential.https://github.com.helper \
    GIT_CONFIG_VALUE_0='!f() { test "$1" = get && echo username=x-access-token && echo "password=$REPOS_TOKEN"; }; f'
else
  echo "       pas de config var REPOS_TOKEN : les dépendances privées ne pourront pas être récupérées"
fi
cd "$(dirname "$0")"
# Sur Heroku, Cargo compile dans le cache du buildpack (CARGO_TARGET_DIR).
target="${CARGO_TARGET_DIR:-target}"

echo "-----> Compilation du serveur"
cargo build --release -p apertis-site --bin apertis-site
mkdir -p site/target/release
cp "$target/release/apertis-site" site/target/release/apertis-site.new
mv -f site/target/release/apertis-site.new site/target/release/apertis-site
echo "       site/target/release/apertis-site prêt"

echo "-----> Compilation des îlots (WebAssembly)"
rustup target add wasm32-unknown-unknown
cargo build -p apertis-site --lib --target wasm32-unknown-unknown --profile wasm-release

# wasm-bindgen doit être la version de Cargo.lock : binaire précompilé, ou compilé
# s'il ne peut pas être téléchargé.
version=$(grep -A1 '^name = "wasm-bindgen"$' Cargo.lock | sed -n 's/^version = "\(.*\)"$/\1/p')
bin="$target/wasm-bindgen-$version"
if [ ! -x "$bin/wasm-bindgen" ]; then
  mkdir -p "$bin"
  curl -sSfL "https://github.com/wasm-bindgen/wasm-bindgen/releases/download/${version}/wasm-bindgen-${version}-x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz --strip-components=1 -C "$bin" \
    || cargo install wasm-bindgen-cli --version "$version" --locked --root "$bin" --bin wasm-bindgen
  [ -x "$bin/wasm-bindgen" ] || mv "$bin/bin/wasm-bindgen" "$bin/"
fi
"$bin/wasm-bindgen" --target web --no-typescript --out-dir site/pkg \
  "$target/wasm32-unknown-unknown/wasm-release/apertis_site.wasm"
echo "       îlots prêts dans site/pkg"
