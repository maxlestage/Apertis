#!/usr/bin/env bash
# Compile le site d'Apertis : le serveur et les îlots (WebAssembly).
# Lancé sur Heroku par RustConfig une fois Rust installé par le buildpack emk/rust ;
# fonctionne aussi à la main depuis le dépôt : ./heroku-build.sh
# Le Procfile démarre site/target/release/apertis-site depuis site/ (public/ et pkg/).
set -euo pipefail

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
