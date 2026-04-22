# Bundled Artifact Provenance

## whisper-cli (bundled engine)

- Source repo: `https://github.com/ggml-org/whisper.cpp`
- Commit: `fc674574ca27cac59a15e5b22a09b9d9ad62aafe`
- Build type: Release, static libs (`-DBUILD_SHARED_LIBS=OFF`)
- Output path in repo: `the-dictator/the-dictator/Resources/bin/whisper-cli`

### Build commands

```bash
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git
cd whisper.cpp
cmake -B build-static -S . -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
cmake --build build-static --config Release -j8
cp build-static/bin/whisper-cli /path/to/the-dictator/the-dictator/Resources/bin/whisper-cli
chmod +x /path/to/the-dictator/the-dictator/Resources/bin/whisper-cli
```

### SHA-256

- `4b04d9ab2f3cc03d50e7ca1c053609842887fe948c2f7cf32f1ba2f06f224869`

## Bundled base model

- Source URL: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin`
- Local output path: `the-dictator/the-dictator/Resources/models/base/model.bin` (intentionally gitignored due GitHub 100 MB limit)

### Fetch command

```bash
scripts/fetch-bundled-base-model.sh
```

### SHA-256

- `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`
