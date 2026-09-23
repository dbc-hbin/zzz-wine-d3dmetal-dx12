# v1.0.5 → v1.1.x 런타임 회귀 분석

분석일: 2026-09-23. 대상 소스: `66a4c55`까지의 배포 변경과 작업 트리의 HUD 수정.

## 결론

1. **FSR 활성 경로의 성능 차이는 격리 D3D12 실행에서 재현했다.** 같은 현재 런타임에서 원본 AMD FSR 3.1.5는 dispatch→fence 완료 중앙값 4.716ms, MetalFX 번역은 8.014ms였다. 차이는 +3.298ms(+69.9%). 이 수치는 합성 입력의 작업 완료 시간이지 게임 FPS나 순수 GPU 시간이 아니다.
2. **Wine 코어 바이너리·빌드 옵션이 바뀌어서 생긴 회귀라는 근거는 없다.** 공식 배포 압축파일 전체 비교에서 실행 엔진, wineserver, ntdll, macdrv, win32u, D3D DLL 및 주요 의존 파일은 동일했다.
3. **렌더러 선택 조건도 바뀌었다.** v1.0.5는 해당 런타임에 DX12 인자를 강제했고, 현재 설치기는 런처의 DX12 설정을 따른다. 기존 OFF 설정의 마이그레이션은 없다. 같은 저장 설정이 같은 렌더러 실행을 보장하지 않는다.
4. GPU 식별 변경, NGX 모듈 제거, FSR builtin 강제 선택은 별도 비교 조건이다. 실제 테스터의 이전 DLSS 사용 여부·자동 프리셋 변경은 관측하지 않았다.
5. HUD 강제 ON 버그는 소스에서 수정하고 자식 프로세스 환경변수 회귀 테스트로 검증했다. 기존 배포 압축파일·설치 런타임은 변경하지 않았다.

확정 사실, 측정 결과, 조건부 추론을 구분한다. 이 분석은 테스터의 FPS 저하 보고를 부정하거나 재확인하기 위한 것이 아니라 그 원인을 분리하기 위한 것이다.

### 후속 소스 수정: 실행 경로 (미배포)

아래 본문의 배포물 비교와 측정값은 분석 당시 상태를 보존한다. 이후 소스에서 다음 실행 경로 수정을 적용했다. 기존 archive나 설치 런타임을 수정했다는 뜻은 아니다.

- **DX12 마이그레이션:** 정확한 v1.0.5 강제 DX12 predicate가 있는 frontend에서, 당시 대상 runtime ID·D3DMetal backend·DX12 지원이 모두 일치하고 저장된 `config_use_d3d12` 키가 없을 때만 ON을 저장한다. 기본 OFF는 자동 저장되지 않았다는 실제 setting lifecycle을 확인했다. 저장된 false는 사용자의 OFF와 구분할 근거가 없어 그대로 보존한다. 다른 지원 runtime, 새 frontend, 이미 설정 기반인 v1.1.x frontend는 추측으로 켜지 않는다. storage 열거·읽기·쓰기 오류에서는 OFF를 유지한다.
- **검증:** 새 마이그레이션 회귀는 수정 전에 실패했고 `node --test scripts/test-dx12-launch-regression.mjs`는 수정 후 4/4 통과했다. normal/Steam 인자 전달, 명시적 OFF, 비대상 지원 runtime, 반복 변환·저장 상태를 포함한다.
- **명시적 SR 선택:** 새 staging helper는 `YAAGL_FSR_UPSCALER=metalfx|native`를 받는다. 미설정·빈 값의 기본은 MetalFX이고 FG 정책은 바꾸지 않는다. 잘못된 값은 Wine 실행 전에 거부한다. 전체 wrapper의 native 선택과 잘못된 값의 child 실행 차단 회귀는 수정 전 실패, 수정 후 기존 HUD/relocation 검사와 함께 4/4 통과했다.
- **실제 provider 확인:** canonical 이름의 게임 DLL을 사용한 격리 D3D12 실행에서 native `0xf5a5ca1e00c01005`와 builtin MetalFX `0x4d46580000000001`을 각각 확인했고 GPU 출력 readback까지 통과했다. [native raw](evidence/2026-09-23-regression-fixes/sr-cost/canonical-native-auto-off.stdout), [MetalFX raw](evidence/2026-09-23-regression-fixes/sr-cost/canonical-metalfx-auto-off.stdout). 이것은 선택 경로의 검증이며 SR 성능 차이가 해결됐다는 증거가 아니다.

사용자 지시에 따라 최종 배포물 반영 검사는 회귀·성능 수정 이후 다음 패키징 단계로 미룬다. 설치된 게임·런타임과 배포 archive는 변경하지 않았다.

## 1. 비교 기준과 배포물 인증

GitHub Releases API의 asset digest와 로컬 SHA-256이 일치하는 것을 확인했다.

| 배포물 | SHA-256 |
|---|---|
| v1.0.5 full runtime | `d4def37c18dc12a9e0cf58e0206044c38d260b82d434a440620b1ca9498c3bdf` |
| v1.1.0 full runtime | `13d0c60f72341e51840f01d49d4866802102fecb3dacc203cca04d196e089aef` |
| v1.1.1 full runtime | v1.1.0과 동일 |
| v1.1.2 full runtime | v1.1.0과 동일 |

로컬 기준:

- `build/release-v1.1.0/v1.0.5-original-runtime.tar.xz`
- `build/release-v1.1.0/v1.0.5-base/wine/`
- `build/release-v1.1.0/wine/`
- `build/release-v1.1.2/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz`

압축파일의 모든 일반 파일을 SHA-256으로 비교하고, 두 추출 디렉터리의 일반 파일이 해당 압축파일과 일치함도 확인했다. 항목 수는 디렉터리를 제외한 일반 파일·링크 기준이다.

| 항목 | 개수 |
|---|---:|
| v1.0.5 항목 | 2,930 |
| 현재 항목 | 2,935 |
| 동일 항목 | 2,920 |
| 추가 | 7 |
| 제거 | 2 |
| 변경 | 8 |

추가: FSR PE/Unix 모듈 4개, 원본 FG private DLL, 실행 helper, stage manifest.

제거: `lib/wine/x86_64-windows/nvngx.dll`, `lib/wine/x86_64-unix/nvngx.so`.

변경: `bin/wine`, D3DMetal 본체, native sidecar, framework CodeResources, 런타임 설명·provenance·graphics inventory·전체 파일 inventory 4개.

소스는 `git diff v1.0.5..HEAD`의 90개 변경 파일을 Wine/build, graphics, FSR/SR/FG, installer/launch/packaging, tests/docs로 나누어 조사했다.

## 2. 실제 D3D12 업스케일러 3방향 비교

### 조건

- 장치: Apple M5 Pro / macOS 27.
- 입력 1920×1080, 출력 3840×2160.
- RGBA16F color/output, R32F depth, RG16F 저해상도 motion, R8 reactive mask.
- 정적인 합성 색상, 일정 depth, zero motion, checker reactive mask.
- 샤프닝 활성, sharpness 0.5.
- 준비 8프레임, 측정 24프레임, 한 프레임씩 제출·fence 완료 대기.
- FFX dispatch 모두 성공. 각 제출의 fence 완료를 확인하고 마지막 출력의 GPU readback을 검사했다. red 채널이 finite이고 sentinel을 덮어썼으며 sanity 범위를 통과했다. 이는 영상 품질 동등성을 증명하는 검사가 아니다.
- 타이머 경계: `ffxDispatch` 시작부터 D3D12 queue fence 완료까지. 명령 기록·제출·스케줄링·대기를 포함한다.

**플래그 구분 및 기록 정정:** 보존한 실제 harness는 context 생성에 `FFX_UPSCALE_ENABLE_HIGH_DYNAMIC_RANGE`를 사용하고, 별개의 dispatch color-transfer flags는 0이다. 기존 게임 로그의 `flags=0`은 `fsr-translator.mm:127-146`에서 기록한 dispatch flags이므로, 이 값으로 게임의 context HDR 생성 설정을 알 수 없다. 처음 이 두 namespace를 비교해 HDR 조건이 게임과 다르다고 해석했던 것은 정정한다. 세 비교군 사이의 생성·dispatch flags는 같지만, 스크린샷과 게임 descriptor의 모든 설정을 그대로 재현한 실험은 아니다. 후속 실험에서는 create HDR=0/1을 별도 조건으로 명시한다.

### 결과

| 경로 | API 호출 wall p50 / p90 (ms) | dispatch→fence wall p50 / p90 (ms) | 출력 red 평균 |
|---|---:|---:|---:|
| v1.0.5 + 원본 AMD FSR 3.1.5 | 0.200 / 0.252 | 4.701 / 4.841 | 0.448829 |
| 현재 + 같은 원본 AMD FSR 3.1.5 | 0.198 / 0.218 | 4.716 / 4.831 | 0.448829 |
| 현재 + MetalFX 번역 | 0.124 / 0.146 | 8.014 / 8.788 | 0.448494 |

같은 현재 런타임에서 MetalFX 경로의 완료 시간은 +3.298ms(+69.9%)였다. API 호출 구간의 경과 시간은 오히려 74µs 짧았다. 이 타이머는 wall clock이며 thread CPU 사용량을 측정한 것이 아니다. 따라서 이 실험의 차이를 PE API 호출 오버헤드만으로 설명할 수 없다. 호출 이후 실행·제출·완료 경로가 주요 조사 대상이다.

이 결과는 다음을 **증명하지 않는다**:

- 게임 전체 FPS가 70% 떨어진다는 주장.
- 순수 GPU 연산 시간이 정확히 3.298ms 늘었다는 주장.
- 동적 장면, 실제 history, 비동기 다중 프레임, present pacing에서 같은 비율이 나온다는 주장.
- 모든 MetalFX 경로 또는 모든 Apple GPU가 원본 FSR보다 느리다는 주장.

### 원본 DLL과 provider 검증

원본은 현재 설치된 게임의 다음 파일을 읽기 전용으로 복사해 사용했다.

`/Applications/Zenless Zone Zero/amd_fidelityfx_upscaler_dx12.dll`

SHA-256: `3eab9a448db1ca09d5aba17d11df5b789649c11d60f1281f4be97bd007ac7d6d`

- AMD 3.1.5 provider: `0xf5a5ca1e00c01005`
- 함께 열거된 AMD 2.3.4 provider: `0xf5a5ca1e00803004`
- 번역 MetalFX provider: `0x4d46580000000001`, `MetalFX (FSR 4 API)`

현재 runtime helper는 canonical FSR DLL의 builtin override를 강제하므로 부모 환경의 `WINEDLLOVERRIDES=...=n`만으로는 원본 경로를 보장할 수 없다. 현재 런타임의 원본 비교군은 임시로 복사한 별칭 DLL을 사용하고 module path와 provider enumeration으로 확인했다. 파일 경로가 원본처럼 보이는 것만으로 native 로딩을 판단하지 않았다.

v1.0.5 항목도 **현재 게임의 같은 원본 DLL + 과거 Wine 런타임** 비교다. 과거 게임 배포 당시 DLL 자체의 provenance를 입증한 것은 아니다.

재현 harness: [fsr-impl-bench.cpp](evidence/2026-09-23-runtime-regression/fsr-impl-bench.cpp)

harness SHA-256: `a45109567c7cd6710522aadeb2915174159feaf3d3fb060fa411ddcf524833c0`

위 표는 실행 당시 도구 출력에서 정리한 결과이며 raw stdout 파일을 가장한 것이 아니다. 원래 실험 작업 디렉터리는 `/tmp/yaagl-upscale-cost/`였다. 이 문서와 보존한 source는 임시 디렉터리의 영속성을 전제하지 않는다.

## 3. MetalFX 내부에서 확인한 비용과 한계

`d3dmetal-pso-cache/metalfx-backend.mm`:

- 크기·형식이 안정적인 dispatch에서 scaler generation을 재사용한다. 매 프레임 factory를 생성하는 구조라고 단정할 근거는 없다.
- 샤프닝이 필요하면 MetalFX 결과를 private output에 쓴 뒤 전체 출력 해상도의 finish/RCAS pass로 caller output에 쓴다.
- 이 finish 경로는 별도의 마지막 copyback을 반드시 추가하는 구조는 아니다.
- composition mask가 없으면 composition-mask combine은 생략된다.
- 입력 크기·사용 조건이 직접 사용 가능하면 입력 staging을 하지 않는다. 게임 backing texture의 실제 크기는 스크린샷만으로 알 수 없다.

별도 native Metal4 격리 실험(1080p→4K, RGBA8, 준비 4회·측정 16회)의 commit→feedback wall 중앙값:

| 조건 | ms |
|---|---:|
| 직접 MetalFX, mask 없음 | 3.164 |
| backend 경유 MetalFX, mask 없음 | 2.606 |
| 직접 MetalFX, reactive mask | 3.333 |
| backend 경유 MetalFX, reactive mask | 2.895 |
| backend 경유 MetalFX, reactive mask + RCAS | 4.929 |

RCAS 비교의 중앙값 차이는 약 2.034ms다. 순차 그룹 측정이고 scheduler 영향을 포함하므로 이를 순수 shader GPU 비용이나 위 D3D12 차이의 정확한 분해값으로 사용하지 않는다. 처음 backend prepare의 RCAS 조건에서 약 413.5ms가 걸렸지만 lazy pipeline 생성이 포함된 cold 비용으로, 정상 프레임의 지속 비용과 구분한다.

**무효 측정 배제:** 이 실험의 `MTL4` feedback은 `GPUStartTime=0`과 uptime 성격의 `GPUEndTime`을 반환했다. 그 차이로 출력된 거대한 `gpu_*` 수치는 무효이며 사용하지 않았다. 직접 native/번역 경로의 작은 wall 차이를 번역층이 더 빠르다는 증거로도 사용하지 않는다.

## 4. FSR 외 실행 정책 회귀 지점

### 4.1 DX12 실행 조건 — `3330dd4`

`installer/resources/AsarTransform.js`의 실제 historical/current 변환을 upstream 0.3.18 fixture에 적용하고 전달 인자를 검사했다. Wine/게임은 실행하지 않았다.

| config.useD3D12 | v1.0.5 | 현재 |
|---|---|---|
| false | `-use-d3d12` 1개 | 없음 |
| true | `-use-d3d12` 1개 | `-use-d3d12` 1개 |

일반 batch와 Steam-patch 경로 모두 동일했다. 현재는 config 설정과 supportsD3d12 capability를 따른다. 설치기는 기존 false 설정을 true로 바꾸지 않는다.

조건부 영향: 이전에 false여도 DX12를 쓰던 사용자는 업데이트 후 다른 렌더러로 실행될 수 있다. 실제 테스터의 argv·저장 설정은 관측하지 않았으므로 FPS 원인으로 단정하지 않는다.

### 4.2 GPU 식별·기능 선택 — `ae40f65`

`bin/wine`/`scripts/wine-launch-wrapper.sh`:

- NVIDIA RTX 5060 (`10de:2d05`) → AMD RX 9070 (`1002:7550`).
- `nvngx.dll`/`nvngx.so` 제거, FSR 모듈·override 추가.
- helper는 game 분기만이 아니라 모든 Wine 실행 경로에서 호출된다.

[INFERENCE] 게임의 기능 노출, 업스케일러 선택, 프리셋 또는 캐시 식별에 영향을 줄 수 있다. 자동 프리셋 초기화, 실제 이전 DLSS 사용, 그에 따른 FPS 차이는 관측하지 않았다.

NGX 제거는 공통 D3D 엔진 제거가 아니다. `libd3dshared.dylib`와 공통 D3D/변환 라이브러리는 유지됐다. 현재 런타임의 원본 FSR·MetalFX 비교군은 둘 다 NGX가 없는 상태이므로, 측정된 두 provider 간 차이를 NGX 제거 탓으로 돌릴 수 없다.

v1.0.5는 stock GPTK NGX 모듈을 포함했다. 그 뒤에 추가됐다가 제거된 실험용 `ngx-hooks.mm`/`temporal.mm` 구현을 v1.0.5 기본 기능으로 혼동하지 않는다. NGX 파일 존재 자체도 게임에서 DLSS가 정상 동작했다는 증명은 아니다.

## 5. 프레임 생성 조사 — 스크린샷의 SR-only 증상과 분리

이 절은 기존 분석 보존 목적이다. 사용자가 FG OFF라고 보고한 후속 스크린샷의 원인을 FG ON 비용으로 설명하지 않는다.

### FG ON 격리 측정

직접 native MetalFX Metal4 보간, 3840×2160, 8프레임·한 프레임 in flight:

- warm frame 4–7 GPU 시간: 6.921 / 6.722 / 6.701 / 6.714ms; 중앙값 6.718ms.
- CPU encode: 약 0.184–0.228ms.
- scratch 할당+residency CPU: 0.048–0.072ms.
- no-UI scratch 4개 실제 allocatedSize 합: 202,637,312B(193.25MiB); 논리 크기 199,065,600B(189.84MiB).
- 이전 색상 history의 논리 크기는 별도 66,355,200B(63.28MiB).

직접 보간만 측정했다. production baseline copy, 색상/depth/MV 변환, scatter, 게임 렌더링, 업스케일링, native swapchain pacing은 포함하지 않는다. scratch 크기가 크다는 사실만으로 CPU allocation이 병목이라고 단정할 수 없으며, 이 실험에서는 allocation CPU 시간이 작았다.

### FG OFF의 조건부 Prepare 경로

`dlls/amd_fidelityfx_framegeneration_dx12/main.c`의 Prepare routing과 `d3dmetal-pso-cache/fsr-framegeneration.mm`의 Snapshot 경로는 presentation이 비활성일 때도 Prepare를 받아 depth/MV를 snapshot한다. 도입은 `099835f`; 이후 `caa7bce`가 copy residency/error 처리를 보강했다.

**게임이 계속 Prepare를 호출하는 경우에만** 해당 복사 비용이 생긴다. 기존 로그의 첫 120 callback 제한 때문에 실제 OFF 후 호출 지속 여부는 확인하지 못했다. 이 사실을 실제 FG 생성이 계속된다는 증거로 사용하지 않는다.

2256×1272 두 texture copy 모델 실험:

- 목적지 실제 allocatedSize: 24,117,248B(23MiB).
- 논리 copy payload: 22,957,056B.
- allocation+residency CPU 중앙값 0.027ms, copy encode CPU 중앙값 0.095ms.
- 완료 wall 1.231–1.366ms. copy-only feedback GPU timestamp는 무효라 제외했다.

## 6. 전체 감사의 배제·낮은 우선순위 항목

| 영역 | 결과와 한계 |
|---|---|
| Wine core | ntdll/server/macdrv/win32u/D3D 구현 및 배포 바이너리 동일 |
| Wine configure | `099835f`에서 FSR DLL Makefile 등록만 추가 |
| Wine build | `build-wine-tuned.sh` 동일, x64/arm64 `-O2 -g` 기존 설정 유지 |
| provenance | upstream `913e31f201d344223bdf3d13a50a41af35893d12`, tuned profile, 14 patch hashes, configure args 등 동일 |
| wrapper 공통 설정 | D3DMetal, Metal4, MetalFX capability, DXR, WINEMSYNC, timeout fix 활성화는 이전과 동일 |
| dependency | converter/default.metallib/DXC/container/MacDeps/GStreamer 등의 교체 증거 없음 |
| PSO/cache | cache/function-cache/stage-cache/key/persistent-cache 구현 변경 없음. GPU 식별·binary identity에 따른 외부 cache 효과까지 배제하는 것은 아님 |
| replay hook | 17개 기존 hook 유지, temporal replay hook 2개 추가. 관련 entry가 호출될 때만 반복 판별 비용 발생 |
| replay CPU microbench | archived sidecar의 실제 predicate, Rosetta x86_64, 20M회×5: baseline callback 약 0.95ns, Metal4 reject 약 2.13ns, legacy reject 약 7.84ns. predicate-only이며 전체 hook/실제 호출 빈도/FPS 증거 아님 |
| hook 초기화 | transport 검증·class lookup 등 load-time 작업. 설정 OFF여도 per-frame texture를 무조건 생성한다는 증거 없음 |
| LoadGraphicsFunctions gate | null-dispatch bypass target 수정. 정상 steady-state PSO 경로의 추가 비용이 아님 |
| 로그 | YAAGL_FSR_LOG opt-in, PE/native 성공 기록은 처음 120회 제한. 초기 I/O와 지속 비용을 구분 |
| 캡처 | 새 helper는 MTL_CAPTURE_ENABLED=0. GPU capture를 강제로 켜는 회귀가 아님 |

## 7. HUD 버그 수정과 검증

원인: `scripts/stage-runtime.py`의 생성 helper가 `MTL_HUD_ENABLED=1`을 무조건 export하여 런처의 OFF 값을 덮어썼다.

- 최초 도입: `099835f`(FSR staging 분기).
- v1.1.0 기본 정책화: `ae40f65`.
- 변경 파일: `scripts/stage-runtime.py`, `scripts/test-fsr-launch-profile.py`, `README.md`, `README.ko.md`.
- helper 강제 export와 `FSR_POLICY`의 `metal_hud=1` 제거.
- 명령: `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-fsr-launch-profile.py -v`.
- 수정 전 unset/empty/0 subtest 실패: 자식에서 모두 1로 관측. ON=1은 통과.
- 수정 후 테스트 2개 통과: unset/empty/0/1 보존 및 기존 relocation/FSR path 동작.

소스만 수정했다. 배포 archive 재생성·재배포·설치 runtime 변경·게임 재실행에 의한 HUD 시각 검증은 하지 않았다.

## 8. 우선순위와 남은 질문

1. 활성 FSR의 강제 MetalFX 대체는 측정된 회귀 후보가 아니라 **이 합성 workload에서는 검증된 비용 증가 경로**다. 실제 게임 FPS에 대한 기여율은 아직 모른다.
2. FSR OFF에서도 저하한다면 먼저 실제 DX12 argv를 맞추고 GPU 식별·기능 선택을 비교해야 한다.
3. RCAS/finish, staging, transport/replay 동기화, resource lifetime을 분해해야 한다. 앞선 완료 시간만으로 각각의 GPU 비용을 배분하지 않는다.
4. DXMT와 D3DMetal의 메모리·프레임 pacing 차이는 별도의 기준선이 필요하다.
5. 임의 성능 수정, native FSR 재기본화, NGX 복구, GPU ID 변경, 설치기 정책 변경은 이 분석에서 수행하지 않았다.

후속: [스크린샷 증거 기반 SR-only 분석](screenshot-sr-analysis-2026-09-23.ko.md).
