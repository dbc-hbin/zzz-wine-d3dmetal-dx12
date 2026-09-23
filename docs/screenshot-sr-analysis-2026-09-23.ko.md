# 스크린샷 증거 기반 SR-only 성능·메모리 분석

분석일: 2026-09-23. 이전 배포 비교: [v1.0.5 → v1.1.x 분석](runtime-regression-analysis-2026-09-23.ko.md).

## 1. 사용자 보고와 증거 범위

사용자 보고는 **FG OFF, FSR 업스케일링만 ON**, DXMT보다 큰 FPS 저하와 높은 메모리 사용량이다. 이 조건을 분석의 전제로 삼았다. FG 보간의 실행 시간·scratch 할당량을 이번 현상의 원인으로 대신 제시하지 않는다.

원본 PNG는 모두 1920×1080이며 첨부 파일과 SHA-256이 일치한다. 채팅 미리보기의 축소 크기와 혼동하지 않는다.

| 증거 | 파일 | SHA-256 |
|---|---|---|
| D3DMetal / MetalFX SR | [원본 PNG](evidence/2026-09-23-screenshot-analysis/d3dmetal-metalfx-sr.png) | `49025a158735a2598b81f21802afd9b38e13f42f499b10b35930c4594aca115a` |
| 사용자 식별 DXMT 기준 | [원본 PNG](evidence/2026-09-23-screenshot-analysis/dxmt-reference.png) | `a0facb240d7e5c0ef3f90ab158fc8a1bf583ff9e102c47a001f126e0f134cca9` |

전체 수동 전사와 비교 제약: [screenshots.json](evidence/2026-09-23-screenshot-analysis/screenshots.json).

### 화면에서 직접 읽은 값

| HUD 항목 | D3DMetal / MetalFX | DXMT 기준 |
|---|---:|---:|
| 장치 / OS | M5 Pro / macOS 27.0 | M5 Pro / macOS 27.0 |
| backend 표시 | D3D12 (Metal 4) | Metal |
| output | 1920×1080 | 1920×1080 |
| presentation | Composited | Composited |
| FPS | 64.17 | 91.82 |
| GPU | 6.30ms | 6.42ms |
| Frame Interval | 15.58ms | 10.89ms |
| App 메모리 표시 | 13.22GB | 8.70GB |
| Metal 메모리 표시 | Metal 4: 5.82GB | Metal: 2.55GB |
| MetalFX input | 1128×624 | 표시 없음 |
| MetalFX target | 1920×1080 | 표시 없음 |
| MetalFX exposure | Auto 0.178101 | 표시 없음 |
| MetalFX scaling | Temporal | 표시 없음 |
| Game Mode | 해당 필드 표시 없음 | Off |

계산되는 관측 차이는 FPS 약 -30.11%, Frame Interval +4.69ms, App 표시 +4.52GB, Metal 표시 +3.27GB다. 입력 픽셀 수는 703,872, 출력은 2,073,600으로 약 33.94%다.

### 이 스크린샷으로 단정하지 않는 것

- 두 카메라와 보이는 오브젝트가 다르다. 엄격한 동일 프레임 A/B가 아니다.
- DXMT 화면은 내부 render resolution이나 업스케일러 설정을 보여주지 않는다. 출력 해상도가 같다고 내부 작업량도 같다고 단정하지 않는다.
- 첫 화면만으로 create HDR flag, sharpening, backing texture 크기, frames in flight, 이전 해상도 전환 이력을 알 수 없다.
- 첫 화면에 Game Mode 필드가 없다는 사실을 Game Mode ON의 증거로 사용하지 않는다.
- App과 Metal 메모리는 통합 메모리에서 중복 계산될 수 있으므로 더하지 않는다. HUD의 GB 표시는 그대로 보존하며, probe의 MiB/bytes와 단위·집계 범위를 구분한다.
- DXMT와 D3DMetal의 GPU 시간 집계 범위가 같다고 보장할 수 없다. `Frame Interval − GPU`를 계산해 CPU 실행 시간이라고 부르지 않는다.
- 첫 화면의 Dispatch 222, Draw 1579, Clear Resource 25, Copy Resource 219, ExecuteIndirect 1은 전체 표시 workload의 카운터다. Copy 219개가 모두 FSR 번역에서 생겼다는 증거가 아니다.
- 단일 메모리 snapshot은 누적 누수, swap, memory pressure를 증명하지 않는다.

## 2. 스크린샷 해상도에서 실제 SR 경로 비교

### 측정 조건

- 입력 1128×624 → 출력 1920×1080.
- 같은 현재 D3DMetal runtime에서 원본 AMD FSR 3.1.5와 builtin MetalFX를 비교했다. DXMT 실행 비교는 아니다.
- 원본 provider ID `0xf5a5ca1e00c01005`, MetalFX ID `0x4d46580000000001`을 실제 enumeration으로 확인했다.
- 원본 DLL은 비정규 이름의 읽기 전용 복사본을 사용해 helper의 canonical builtin override를 피했다. 게임 파일을 변경하지 않았다.
- RGBA16F color/output, R32F depth, RG16F motion, R8 reactive mask, 정적인 합성 패턴.
- 준비 8프레임 + 측정 24프레임, 한 제출씩 D3D12 fence 완료를 기다렸다. FG context는 생성하지 않았다.
- 모든 dispatch 성공, fence 완료, 출력의 finite/sentinel/sanity readback 검사를 통과했다. 이 검사는 영상 품질 동등성 검증이 아니다.
- archived runtime helper의 HUD 강제 ON 정책이 적용되는 환경이다. 두 provider 모두 같은 runtime을 사용했다. 앞서 수정한 소스로 archive를 다시 만든 실험은 아니다.

### 결과: dispatch 시작 → fence 완료 wall time

각 숫자는 ms이며 `중앙값 / p90`이다. 별도 실행 케이스 사이의 작은 차이를 특정 설정의 순수 비용으로 해석하지 않는다.

| create 설정 | 샤프닝 | 원본 AMD 3.1.5 | MetalFX | 중앙값 차이 |
|---|---|---:|---:|---:|
| HDR off, auto exposure off (`0`) | ON, 0.5 | 1.954 / 2.099 | 4.221 / 4.677 | +2.267 |
| HDR off, auto exposure off (`0`) | OFF | 2.246 / 2.650 | 4.054 / 4.458 | +1.808 |
| HDR on, auto exposure off (`1`) | ON, 0.5 | 2.196 | 4.901 | +2.705 |
| HDR off, auto exposure on (`32`) | ON, 0.5 | 2.399 / 2.481 | 4.113 / 4.464 | +1.714 |

모든 케이스의 **dispatch color-transfer flags는 0**이다.

Auto Exposure ON 케이스는 스크린샷의 `Exposure Auto` 표시를 반영하기 위해 추가했다. 스크린샷의 모든 create flag, 입력 내용, sharpening을 알고 있다는 뜻은 아니다.

**관측 결론:** 스크린샷과 같은 입출력 크기에서도 FG 없이 MetalFX 경로의 완료 시간이 원본 AMD FSR보다 길었다. Auto Exposure 케이스의 차이는 +1.714ms(+71.5%)였다. 샤프닝 OFF에서도 차이가 남으므로, 4K 출력이나 RCAS만으로 설명되는 현상이 아니다.

이것을 스크린샷의 +4.69ms 중 특정 비율이 설명됐다고 환산하지 않는다. 비교 renderer, 장면, 비동기 실행, frame pacing이 다르다. 순수 GPU 시간 또는 게임 FPS를 측정한 실험도 아니다.

### API 호출과 완료 대기 구간

Auto Exposure ON 케이스의 중앙값:

| 측정 구간 | 원본 AMD | MetalFX |
|---|---:|---:|
| FFX API 호출 host elapsed | 0.187ms | 0.112ms |
| command list close | 0.001ms | 0.001ms |
| submit 시작 → fence 완료 | 2.213ms | 4.007ms |
| host event wait | 2.180ms | 3.970ms |

타이머는 wall clock이며 thread CPU 사용량을 측정한 것이 아니다. 일부 raw 필드의 `_cpu` 명칭도 host-side elapsed 구간이라는 의미로 해석한다. 각 구간 중앙값을 더해 전체 중앙값을 정확히 재구성할 수는 없다.

MetalFX는 API 호출 시간이 더 짧았지만 완료를 기다리는 구간은 더 길었다. 이 결과는 FFX API 진입부 비용보다 **명령 제출 이후의 replay·GPU 실행·스케줄링·완료 경로**를 우선 조사해야 함을 보여준다. 이들 세부 기여율을 분리한 것은 아니다.

또한 benchmark는 작업 완료 시간을 재려고 매 프레임 fence를 기다린다. **게임이나 번역기가 실제 게임 실행 중 매 프레임 같은 CPU wait를 강제한다는 증거가 아니다.** Metal encoder의 fence ordering도 host CPU wait와 구분해야 한다.

### 소스에서 확인한 pass와 flag 의미

- `fsr-contract.cpp`는 create HDR bit0를 `FeatureFlagIsHDR`에, create auto-exposure bit5를 `FeatureFlagAutoExposure`에 매핑한다.
- 별도의 dispatch sRGB/PQ bits가 `ColorTransfer`를 결정한다. dispatch flags 0은 Linear다.
- `metalfx-backend.mm`은 non-linear transfer일 때 `linearColor`와 pre-linearize 작업을 준비한다. 이번 dispatch flags 0 케이스에 그 pass를 추가 비용으로 계산하지 않는다.
- sharpening은 별도로 output shadow와 finish/RCAS pass를 필요로 할 수 있다. 그러나 sharpening OFF에서도 완료 시간 차이는 남았다.
- 자동 노출은 descriptor의 `autoExposureEnabled`에 전달된다. HUD가 표시한 Auto를 무시하고 create flags 0 케이스만으로 정확한 화면 재현이라고 주장하지 않는다.

**기존 기록 정정:** `fsr-translator.mm`의 JSON `flags`는 dispatch packet의 flags다. 생성 시 HDR flag를 기록한 값이 아니다. 기존 로그 `flags=0`과 예전 probe의 create HDR=1을 서로 모순이라고 해석했던 것은 정정했다. 이전 문서에도 두 namespace를 분리해 기록했다.

### 이전 4K 결과와의 관계

같은 create HDR=1, dispatch flags 0, sharpening ON 조건의 중앙값:

| 크기 | 원본 AMD | MetalFX | 차이 |
|---|---:|---:|---:|
| 1920×1080 → 3840×2160 | 4.716ms | 8.014ms | +3.298ms |
| 1128×624 → 1920×1080 | 2.196ms | 4.901ms | +2.705ms |

방향은 같지만 절대 차이는 출력 픽셀 수에 비례하지 않았다. 실험 실행 시점·고정 비용·스케줄러·입출력 비율 등도 달라지므로, 이 표만으로 고정 비용을 수학적으로 역산하지 않는다.

## 3. 보존된 성능 증거와 재현

- [probe source](evidence/2026-09-23-screenshot-analysis/performance/fsr-screenshot-bench.cpp)
- [D3D12 queue/fence timing helper](evidence/2026-09-23-screenshot-analysis/performance/d3d12-test-helpers.hpp)
- [compile/run commands](evidence/2026-09-23-screenshot-analysis/performance/commands.sh)
- [native auto ON raw stdout](evidence/2026-09-23-screenshot-analysis/performance/native-on-auto.stdout)
- [MetalFX auto ON raw stdout](evidence/2026-09-23-screenshot-analysis/performance/mfx-on-auto.stdout)
- [native flags0 + sharpen ON](evidence/2026-09-23-screenshot-analysis/performance/native-on-sdr.stdout)
- [MetalFX flags0 + sharpen ON](evidence/2026-09-23-screenshot-analysis/performance/mfx-on-sdr.stdout)
- [native flags0 + sharpen OFF](evidence/2026-09-23-screenshot-analysis/performance/native-off-sdr.stdout)
- [MetalFX flags0 + sharpen OFF](evidence/2026-09-23-screenshot-analysis/performance/mfx-off-sdr.stdout)
- [native HDR ON](evidence/2026-09-23-screenshot-analysis/performance/native-on-hdr.stdout)
- [MetalFX HDR ON](evidence/2026-09-23-screenshot-analysis/performance/mfx-on-hdr.stdout)

실험은 현 장비의 Xcode/llvm-mingw 및 staging runtime을 사용했다. 재실행 명령은 임시 작업 디렉터리와 별도 Wine prefix를 쓰며, 보존한 canonical stdout 대신 `/tmp`의 별도 출력 디렉터리에 쓴다. 도구·runtime·게임 원본 DLL 경로는 commands 파일의 prerequisites다.

처음 Auto 케이스에는 실제 create 값과 달리 HDR-only 출력식을 사용해 `create_flags=0`으로 찍는 probe label 버그가 있었다. 잘못 표시된 첫 raw 출력은 `*-labelbug.stdout`으로 남겼으며 정량 결론에 쓰지 않았다. 출력식을 실제 `createFlags` 변수로 고친 뒤 다시 얻은 canonical 두 파일은 `create_flags=32`, provider ID, `result=PASS`를 확인했다. raw 캡처 문자열을 사후에 32로 고쳐 쓴 것이 아니다.

raw 로그의 Vulkan 미지원 메시지는 Vulkan을 끈 동일 Wine 빌드의 진단이다. 이번 실행은 D3D12/D3DMetal로 성공했다. MetalFX HUD metric 등록 메시지도 보존했으며 삭제하거나 성공을 가장하지 않았다. GPU-only timestamp는 유효하지 않아 GPU 비용 숫자로 사용하지 않았다.

## 4. 메모리 증거를 읽는 기준

스크린샷에서 App +4.52GB, Metal 표시 +3.27GB는 실제 관측 차이지만, FSR 번역분만 분리한 값은 아니다. DXMT와 D3DMetal의 renderer/자원 보유량, 플레이 시간, 씬 스트리밍, 이전 설정 전환, 캐시 상태가 통제되지 않았다.

1920×1080 RGBA16F 텍스처 한 장의 논리 크기는 16,588,800B, 약 15.82MiB다. 따라서 single output shadow 하나로 수 GB 차이를 설명하지 않는다. 반대로 실행 lease가 여러 장을 오래 유지한다면 장당 크기만 보고 총비용이 작다고 단정해서도 안 된다.

메모리 분석에서는 다음을 별도로 기록한다.

1. Metal `currentAllocatedSize`: 장치가 보고하는 Metal allocation bytes.
2. process footprint/RSS: host 프로세스 메모리; Metal 값과 단순 합산하지 않는다.
3. C++ generation / PreparedFrame / ExecutionLease 수명.
4. 실제 Objective-C MetalFX scaler 객체 수명.
5. GPU 완료, command allocator reset, context destroy, autorelease pool drain의 구분.

`ScalerGeneration`의 C++ destructor가 실행됐다는 사실만으로 그 안의 실제 MetalFX 객체나 모든 GPU 메모리가 즉시 해제됐다고 주장하지 않는다. 반대로 destructor 이후 allocation이 남아 있다는 사실만으로 우리 코드의 영구 누수 또는 Apple framework cache라고 단정하지 않는다.

## 5. 실제 메모리 수명 실험

세 실험 모두 x86_64로 빌드하고 Rosetta에서 실행했다. FG를 만들지 않았으며, 설치 런타임·게임 파일을 바꾸지 않았다. instrumentation과 생성 코드는 임시 복사본에만 적용했다. 아래 MiB는 1024² bytes 기준이다.

### 5.1 일정 해상도와 입력 크기 변경

실제 backend를 사용해 Auto Exposure와 sharpening을 켜고 1128×624 → 1920×1080 SR을 실행했다. 각 프레임에서 실제 Metal4 완료 feedback을 기다린 뒤 allocator를 reset했다.

| 측정 지점 | Metal currentAllocatedSize | process footprint | RSS |
|---|---:|---:|---:|
| 장치 baseline | 0.06MiB | 5.08MiB | 5.86MiB |
| caller texture 생성 | 27.98MiB | 5.42MiB | 6.15MiB |
| 준비 8프레임 완료 | 239.75MiB | 306.98MiB | 17.53MiB |
| 일정 해상도 64프레임 완료 | 239.75MiB | 306.99MiB | 17.56MiB |
| 입력 1056×594로 변경 후 | 425.62MiB | 496.19MiB | 22.32MiB |
| 입력 1128×624로 복귀 후 | 601.12MiB | 674.84MiB | 26.96MiB |
| 다시 일정 해상도 64프레임 | 601.12MiB | 674.86MiB | 27.00MiB |
| backend·texture 해제 / drain | 585.06MiB | 674.67MiB | 26.99MiB |
| compiler 해제 | 585.06MiB | 674.67MiB | 26.99MiB |

**이 probe의 정상 reset 경로에서는 일정 해상도 프레임 수에 따라 계속 증가하지 않았다.** 반면 입력 크기를 두 번 바꾸자 Metal allocation이 +361.37MiB 늘고, 이후 일정 해상도 실행에서는 그 수준을 유지했다.

현재 SR backend는 하나의 current generation을 사용한다. 크기/형식 조건이 바뀌면 새 scaler를 만들며 descriptor는 synchronous initialization을 요청한다. 이것을 FG 쪽의 8-variant cache와 혼동하지 않는다. C++ ScalerGeneration destructor는 두 교체와 최종 feature reset에서 실행됐다.

이 결과만으로 실제 게임이 입력 크기를 자주 바꾼다고 주장하지 않는다. 기존에 읽은 초기 게임 로그의 각 120 dispatch 구간은 render 크기가 일정했다. 스크린샷도 과거 설정 전환 이력을 보여주지 않는다.

### 5.2 우리 backend를 제거한 native scaler 수명 대조군

Objective-C MetalFX factory를 직접 호출해 A(1128×624), B(1056×594), A2(1128×624) scaler를 만들고, 각각 caller가 소유한 +1을 release한 뒤 autorelease pool을 비웠다. 이 대조군은 **create/release만 수행하며 encode하지 않는다.**

| scaler 생성 단계 | 생성 후 Metal allocation | caller release / pool drain 후 |
|---|---:|---:|
| A | 178.19MiB | 178.19MiB |
| B | 337.45MiB | 337.45MiB |
| A2 | 496.89MiB | 496.89MiB |

객체에 owner를 다시 retain하지 않는 deallocation sentinel을 부착했다. 일반 NSObject 대조군에서는 sentinel dealloc 카운터가 1 증가했지만, 세 scaler의 caller release, compiler/device release, 마지막 outer pool drain까지 카운터는 더 증가하지 않았다. 즉, **이 관측 구간에서 native scaler의 deallocation은 관측되지 않았다.**

우리 backend의 소유권은 `newTemporalScaler...`의 +1을 그대로 generation에 넣고 destructor에서 한 번 release하는 형태다. 이 경계에서 명백한 이중 retain은 찾지 못했고, wrapper 없이 호출한 native 대조군에서도 보유 현상이 나타났다.

그러나 이 결과로 내부 reference holder, 영구 누수, 의도된 cache, 지연 정리를 구분할 수 없다. 장시간 이후의 회수 여부를 측정한 것도 아니다. 아래 ANE 진단 조건을 반드시 함께 읽어야 한다.

### 5.3 실제 GPU 완료와 allocator Reset은 다른 회수 경계

`d3dmetal-transport.mm`의 OwnerState는 replay마다 ExecutionLease를 vector에 추가한다. owner는 native allocator의 ExtendResourceLifetime으로 이전되며 matching release는 allocator Reset/destruction에 연결된다. GPU 완료만으로 vector의 개별 lease를 제거하는 경로는 이 구조에 없다.

따라서 동일 recorded command/allocator를 reset 없이 반복 실행하는 별도 경계 실험을 수행했다. 16회 모두 실제 MetalFX encode를 했고 매번 GPU 완료를 기다렸다.

| 지점 | Metal currentAllocatedSize |
|---|---:|
| record 완료, replay 전 | 222.77MiB |
| replay 1회 완료 | 222.77MiB |
| replay 4회 완료 | 288.95MiB |
| replay 16회 완료 | 481.70MiB |
| 모든 GPU 작업 완료 | 481.70MiB |
| 그 뒤 allocator Reset | 240.77MiB |

4→16 구간은 replay당 약 **16.06MiB** 증가했다. 1080p RGBA16F 한 장의 15.82MiB와 가까운 크기다. Reset에서 **240.93MiB**가 떨어졌고, baseline보다 약 18MiB 남았다. footprint는 같은 시점에 Metal allocation처럼 즉시 떨어지지 않았으므로 서로 다른 메모리 지표를 동일시하지 않는다.

**확인한 번역층 보유 동작:** 이미 GPU 실행을 마친 scratch도 owner/allocator가 retire하지 않으면 여러 execution lease에 남는다. 이 실험은 하나의 owner를 의도적으로 유지한 경계 조건이다. 실제 게임의 allocator reset 주기나 해당 replay 패턴은 아직 관측하지 않았다. 따라서 스크린샷의 3.27GB 차이가 이 경로 때문이라고 확정할 수 없다.

처음 instrumentation 실행의 Objective-C class 중복 경고는 숨기지 않고 test-only class 이름을 분리해 해결했다. 최종 보존한 transport 출력에는 그 경고가 없고, `replays=16 leases_until_allocator_reset=16`과 PASS를 확인했다. 수 GB나 OOM까지 증가시키는 stress는 수행하지 않았다.

### 5.4 ANE 진단과 실험 한계

메모리 실험의 raw 출력에는 다음 Apple 진단이 남아 있다.

```text
Error Domain=com.apple.appleneuralengine Code=26
doCompileModel:csIdentity:sandboxExtension:options:qos:withReply:: Bad argument error
```

진단을 suppress하거나 raw 로그에서 삭제하지 않았다. non-nil scaler 생성과 backend/transport의 실제 Metal4 완료를 막지는 않았지만, 이것은 깨끗한 ANE/model 실행 경로의 증명이 아니다. native create/release 대조군은 GPU encode나 출력 readback을 수행하지 않는다.

따라서 native 보유 현상은 **해당 진단이 발생한 이 OS·장치·probe 조건에서의 관측**이다. 진단이 없는 환경에 그대로 일반화하거나 Apple framework의 영구 누수로 명명하지 않는다. 검사한 기존 `game-native.log`와 `post-toggle-native.log`에는 같은 진단 문자열을 찾지 못했지만, 로그 범위가 완전한 진단 수집이라는 증거는 없으므로 게임에서는 절대 발생하지 않는다는 결론도 아니다. 스크린샷 사용자의 실행 로그에서 동일 진단이 있었는지는 알 수 없다.

### 메모리 재현 자료

- [SR memory probe source](evidence/2026-09-23-screenshot-analysis/memory/sr-memory-probe.mm) / [runner](evidence/2026-09-23-screenshot-analysis/memory/run-sr-memory-probe.sh) / [raw 출력](evidence/2026-09-23-screenshot-analysis/memory/sr-memory-probe.stdout.txt)
- [native scaler lifetime control](evidence/2026-09-23-screenshot-analysis/memory/native-scaler-lifetime-control.mm) / [runner](evidence/2026-09-23-screenshot-analysis/memory/run-native-scaler-lifetime-control.sh) / [raw 출력](evidence/2026-09-23-screenshot-analysis/memory/native-scaler-lifetime-control.stdout.txt)
- [transport instrumentation/runner](evidence/2026-09-23-screenshot-analysis/memory/run-d3dmetal-transport-memory.sh) / [raw 출력](evidence/2026-09-23-screenshot-analysis/memory/d3dmetal-transport-memory.stdout.txt)

runner는 production source를 수정하지 않고 임시 복사본을 계측한다. 실험용 resource/replayer/allocator fixture와 native Metal4 실행을 사용하므로 실제 게임의 모든 command scheduling을 재현한 것은 아니다.

## 6. 최종 판단과 다음 수정의 우선순위

| 항목 | 이번에 확정한 범위 | 확정하지 못한 범위 |
|---|---|---|
| SR 성능 | 스크린샷 크기에서도 원본 FSR보다 MetalFX 완료 시간이 길다. 샤프닝 OFF와 Auto Exposure ON에서도 남는다 | 실제 DXMT→D3DMetal 게임 FPS 차이 중 정확한 기여율, GPU kernel/CPU replay/queue scheduling별 시간 |
| 일정 크기의 메모리 | 정상 completion/reset 경로에서 측정한 steady 구간은 평평했다 | 모든 게임 command/context 패턴에서 누수가 없다는 주장 |
| resize / scaler 생성 | input 크기 변경 뒤 allocation이 증가하고 native create/release 대조군에서도 scaler dealloc이 관측되지 않았다 | 내부 retention 이유, 장시간 회수 여부, 진단 없는 환경과 게임에서 같은 현상 |
| execution lease | 동일 owner의 완료된 replay scratch가 allocator Reset까지 유지되며 Reset 시 큰 폭으로 내려갔다 | 실제 게임이 그런 owner/reset 패턴을 쓰는지, 스크린샷 수 GB 차이의 원인인지 |
| FG | 실험에서는 생성하지 않았다 | FG ON 비용을 이번 증상의 설명으로 사용하지 않음 |

수정 후보의 순서는 다음과 같다. 이번에는 원인 분석과 증거 보존만 했으며 아래 성능 변경을 적용하지 않았다.

1. **SR 완료 경로 분해:** MetalFX 자체 작업, replay/encoder 전환, GPU ordering, queue scheduling을 구분한다. API 호출이 빠르다는 이유로 전체 번역 비용이 작다고 판단하지 않는다. 샤프닝만 제거하면 해결된다는 근거도 없다.
2. **ExecutionLease retirement 검토:** 이미 완료된 execution scratch를 allocator Reset까지 모두 보유해야 하는지 검토한다. 실제 완료와 연결된 회수가 필요하며, GPU가 참조 중인 lease를 즉시 비우는 수정은 안전하지 않다. 부분 encode 실패와 repeated/concurrent replay 수명도 보존해야 한다.
3. **scaler generation 변경 최소화 검토:** 실제 게임의 context 생성·입력 크기 변경 빈도와 native scaler 보유량을 함께 기록한다. API contract와 history 정확성을 유지하면서 factory 재생성을 줄일 수 있는지 검토한다. 확인 없이 작은 입력을 큰 descriptor로 강제 재사용하지 않는다.
4. **게임 메모리 차이의 마지막 연결:** 같은 장면·시작 상태에서 D3DMetal 원본 FSR / MetalFX와 DXMT의 allocation 추이, live owner/lease 수, allocator Reset, scaler 생성·해제를 맞춰 관측해야 스크린샷의 수 GB 차이를 귀속할 수 있다. 현재 두 PNG만으로 그 연결을 만들지 않는다.

이번 산출물은 분석 문서 2개, 원본 이미지·전사, 재현 source/commands/raw 출력이다. 앞서 적용한 HUD 소스 수정을 제외하고 production 코드·배포 archive·설치 runtime·게임 상태는 변경하지 않았다.

## 7. 후속 소스 수정과 재현 결과 (미배포)

1~6절은 수정 전 분석과 측정값을 보존한다. 아래는 그 이후의 소스 작업이다. 기존 배포 archive·설치 runtime·게임은 변경하지 않았으며, 최종 패키징 검사는 사용자 지시에 따라 다음 배포 단계로 미룬다. DX12 마이그레이션과 명시적 원본 FSR/MetalFX 선택은 [실행 경로 수정 기록](runtime-regression-analysis-2026-09-23.ko.md#후속-소스-수정-실행-경로-미배포)에 정리했다.

### 7.1 입력 크기 왕복 시 scaler 재생성 축소

처음부터 최대 입력을 할당하지 않고 실제 첫 입력으로 시작한다. 이후 더 작은 active input이 기존 capacity와 native scale 제약 안에 들어오면 같은 scaler를 유지한다. active 크기 변화의 history reset은 유지하며, 입력 증가·출력/format 변경 등 새 configuration이 필요한 경우는 재생성을 허용한다. 가로·세로 최대값을 합친 capacity가 scale 제약을 위반하면 유효한 exact-size configuration으로 돌아간다.

작은 입력은 descriptor 크기에 맞게 staging하고 가장자리 값을 확장한다. capacity만 큰 caller texture의 비활성 영역을 그대로 넘기면 poison 값이 화면에 섞이는 것을 재현했으므로, 그 경우도 staging 대상이다. Metal4에서는 staging→첫 edge copy와 이후 종속 self-copy 사이에 `MTLStageBlit`→`MTLStageBlit`, `MTL4VisibilityOptionDevice` barrier를 넣는다. encoder 바깥의 fence만으로는 같은 encoder 안의 종속 copy를 정렬하지 못한다. 독립된 texture 사이에는 이 barrier를 추가하지 않는다.

Metal4와 Apple10의 legacy GPU 경로에서 CPU edge-extension 대조군, 비활성 padding poison 불변성, 같은 descriptor/history 조건의 direct native MetalFX 출력 일치를 확인했다. Metal4 display-resolution motion과 sRGB padding 경로도 검사했다. 서로 다른 크기의 descriptor 간 미세한 출력 차이를 임의 허용 오차로 숨기지 않았다. low-resolution motion의 58/16,384 pixel, 최대 2/255 차이는 direct native retained-vs-fresh에서도 동일했고, 같은 configuration에서는 bit-exact였다.

기존 §5.1과 같은 A(1128×624)→B(1056×594)→A, 출력 1920×1080 재현에서:

| 지점 | 수정 전 Metal 할당량 | capacity 재사용 후 |
|---|---:|---:|
| warm 8 / steady 64 | 239.75MiB | 239.75MiB |
| B로 축소 | 425.62MiB | 251.19MiB |
| A 복귀 / 추가 steady 64 | 601.12MiB | 239.75MiB |
| backend·caller textures 해제 후 | 585.06MiB | 223.69MiB |

왕복 후 추가 **361.37MiB**가 남던 이 재현을 제거했다. B에서의 일시적 staging 비용은 남는다. teardown 뒤 223.69MiB가 여전히 관측되며 ANE Code 26 진단도 남아 있으므로 native 내부의 모든 보유를 해제했다거나 스크린샷의 3.27GB 차이를 해결했다는 주장은 아니다. 입력 capacity가 실제로 커져야 하는 경우의 factory 생성도 없앤 것이 아니다.

- [수정 후 메모리 raw](evidence/2026-09-23-regression-fixes/scaler/current-sr-memory-probe.stdout.txt)
- [native 회귀 raw](evidence/2026-09-23-regression-fixes/scaler/backend.log) / [빌드·source hash·결과](evidence/2026-09-23-regression-fixes/scaler/results.json)
- [최종 Metal4 barrier·legacy scoped GPU raw](evidence/2026-09-23-regression-fixes/scaler/edge-reuse.log) / [빌드·실행 명령·최종 source hash](evidence/2026-09-23-regression-fixes/scaler/edge-reuse-build-run-hashes.txt). 앞의 전체 suite와 메모리 측정 이후 추가한 barrier는 allocation 경로를 바꾸지 않으며, 바뀐 copy 경로를 별도 실행했다.

### 7.2 실제 GPU 완료에서 execution lease 회수

Metal4 command buffer 자체가 아니라 실제 queue commit의 `MTL4CommitOptions` feedback에 회수를 연결했다. layout v10의 새 commit hook은 기존 native feedback과 commit을 보존한다. legacy는 command buffer completion handler를 사용한다. encode 전에 owner가 typed SR/FG lease slot을 보유하고, 완료 callback은 raw owner pointer가 아닌 공유 slot을 통해 회수한다. callback 등록 실패·미제출·부분 encode 실패에서는 owner의 안전한 보유 경계를 유지하며, 아직 GPU가 사용할 수 있는 lease를 성공 여부만 보고 즉시 버리지 않는다.

지연·역순 완료, 같은 command-buffer 주소 재사용, owner 소멸, 동시 회수, SR/FG lease 및 legacy completion을 포함한 native lifetime 회귀를 통과했다. 별도로 격리된 전체 Wine/D3DMetal 사본에서 **D3D12 command list를 한 번만 기록하고 같은 list/allocator로 16회 실행**했다. 각 GPU fence를 기다렸지만 loop 안에서는 allocator Reset을 호출하지 않았다.

- 실제 sidecar에서 같은 feature/eval의 replay 1~16과 **16개 Metal4 feedback**을 관측했다. 각 callback은 대응 fence 반환 전에 실행됐고 owner slot은 매번 **0개**였다.
- encode 직후 Metal 할당량은 첫 replay 432.766MiB, 이후 2~16회 모두 **430.406MiB**였다. 마지막 allocator Reset에도 남은 slot은 0개였다. callback 직전·직후의 물리 allocation 수치는 같았으므로, 이는 즉시 물리 메모리 반환이 아니라 **완료 lease 회수와 bounded reuse**의 증거다.
- GPU readback은 `interiorMean=0.250244`, `borderMaximum=0`으로 통과했다. 이 실제 D3D12 probe는 caller 3840×2160, temporal 3744×2088, placement (48,36)이다. §5.3의 1080p native fixture와 절대 MiB를 직접 비교하지 않는다.
- 계측은 임시 sidecar 사본에만 넣었다. production의 frame별 telemetry나 제어 API를 추가하지 않았다. 이 재현만으로 실제 게임의 allocator 사용 패턴이나 전체 메모리 차이를 귀속하지 않는다.

증거: [실제 replay/feedback raw](evidence/2026-09-23-regression-fixes/lifetimes/replay16-run.log), [D3D12 probe 빌드·실행 결과](evidence/2026-09-23-regression-fixes/lifetimes/replay16-run-evidence.json), [계측 sidecar 빌드 provenance](evidence/2026-09-23-regression-fixes/lifetimes/instrumented-build-manifest.json), [native lifetime suite 결과](evidence/2026-09-23-regression-fixes/lifetimes/lifetime-suite-results.json).

### 7.3 비계측 production 사본의 실제 SR/FG 검증

최종 barrier 수정이 포함된 source에서 `testControls=false` sidecar를 빌드하고, 격리된 전체 runtime 사본에 layout v10 D3DMetal patch와 함께 넣었다. deep/strict 서명을 확인한 뒤 Metal API Validation을 켜고 기존 실제 D3D12 runner를 실행했다.

| 경로 | 결과와 provenance |
|---|---|
| Metal4 SR | [PASS](evidence/2026-09-23-regression-fixes/lifetimes/pre-legacy-capture-fix-sr-metal4-run-evidence.json): 출력 내부 평균 0.250244, 바깥 border 0 |
| Metal4 FG | [PASS](evidence/2026-09-23-regression-fixes/lifetimes/pre-legacy-capture-fix-fg-metal4-run-evidence.json): builtin/native 경로, HDR·HUD-less·swapchain readback 포함 |
| legacy SR | [수정 후 PASS](evidence/2026-09-23-regression-fixes/lifetimes/post-fix-sr-legacy-run-evidence.json): 출력 내부 평균 0.250244, 바깥 border 0 |
| legacy FG | [수정 후 PASS](evidence/2026-09-23-regression-fixes/lifetimes/post-fix-fg-legacy-run-evidence.json): builtin/native 경로, HDR·HUD-less·swapchain readback 포함 |

실제 legacy 실행에서는 CPU lifetime fixture가 놓친 callback capture 오류를 추가로 발견했다. `std::visit([&])` 안의 Objective-C block이 바깥 `slot`의 reference capture를 따라가면서, 등록 scope가 끝난 후 `mutex lock failed: Invalid argument`와 GPU timeout이 발생했다. visitor 안에 소유권을 가진 `completionSlot` 값 복사본을 만들고 지연 block이 그 값을 capture하도록 수정했다. 같은 SR legacy runner가 [수정 전 실패](evidence/2026-09-23-regression-fixes/lifetimes/pre-fix-sr-legacy-run.log), 수정 후 통과했으며 FG legacy도 통과했다. 예외를 숨기거나 timeout만 늘리지 않았다.

Metal4 두 검사는 legacy-only capture 수정 전 실행이고, 수정 후에는 영향을 받은 legacy 두 경로를 실행했다. 따라서 **한 최종 바이너리로 4개 경로를 모두 재실행했다는 주장은 하지 않는다.** [수정 전 manifest](evidence/2026-09-23-regression-fixes/lifetimes/pre-legacy-capture-fix-sidecar-build-manifest.json)와 [수정 후 manifest](evidence/2026-09-23-regression-fixes/lifetimes/production-sidecar-build-manifest.json)를 구분해 보존했다. 배포 archive 재구축·설치된 게임 확인은 여전히 다음 배포 단계의 작업이다.

### 7.4 중단 후 최종 source·바이너리 재확인

작업을 재개하면서 production sidecar manifest의 모든 source SHA-256이 현재 작업 트리와 일치함을 확인했다. 격리 runtime의 sidecar SHA-256은 manifest의 `77d50505a51a8e863b081eec4e4cf066f89bbf7da8f579484ac771543713a43b`와 같고, D3DMetal framework의 deep/strict 서명 검사도 통과했다. 위 §7.3의 시점 제한을 대체하는 **새 실행**으로, 이 동일한 최종 sidecar에서 Metal4 SR·FG 및 legacy SR·FG 네 경로를 별도 Wine prefix로 실행했다. 각각 `FSR_TRANSLATOR_D3D12_PASS`, `FSR_FRAMEGENERATION_D3D12_PASS`, `FSR_TRANSLATOR_D3D12_PASS`, `FSR_FRAMEGENERATION_D3D12_PASS`였다. SR 출력은 `interiorMean=0.250244`, `borderMaximum=0`; FG는 builtin/native, HUD-less, HDR 및 swapchain readback 경로를 포함한다. 새 실행의 machine-readable evidence는 `/tmp/yaagl-recovery-smoke-20260923/{sr-metal4,fg-metal4,sr-legacy,fg-legacy}/run-*/evidence.json`에 있으며, 이 임시 경로의 영속성은 전제하지 않는다.

native backend·Metal4/legacy transport·lifetime suite, HUD/helper 4건, DX12 migration 4건도 현재 소스에서 통과했다. Lifetime fixture에는 legacy FG completion을 command-buffer release 전 호출하고 lease가 그 시점에 회수되는 assertion을 추가했다. 실제 callback capture는 위 legacy D3D12 실행으로 별도 검증한다. 이 검증은 설치된 게임의 프레임율이나 최종 배포 archive의 변경을 뜻하지 않는다.

### 7.5 중단된 SR 비용 분해 실험의 결론

남아 있던 실험을 격리된 Wine/D3DMetal 사본에서 완료했다. 먼저 같은 계측 소스의 D3DMetal borrowed compiler와 public-default compiler 순차 실행은 scaler counter 구간 p50 **3.2985ms / 2.9938ms**였다. caller texture의 public backing 정보를 맞추고 첫 프레임만 history reset한 별도 native 실행은 **1.08595ms**였다. 서로 다른 프로세스·실행 순서의 차이를 compiler나 특정 복사 비용으로 귀속할 수 없다. [borrowed raw](evidence/2026-09-23-regression-fixes/sr-cost/d3dmetal-same-source-borrowed.stdout), [default raw](evidence/2026-09-23-regression-fixes/sr-cost/d3dmetal-same-source-default.stdout), [matched native raw](evidence/2026-09-23-regression-fixes/sr-cost/native-resource-matched-corrected-history.stdout).

그 다음 **한 D3DMetal 프로세스의 borrowed device/compiler**에서 직접 native backend를 먼저 32프레임 실행하고, 같은 프로세스의 FFX→D3DMetal 경로를 32프레임 실행했다. 준비 8프레임을 제외한 각 24프레임의 counter 구간 p50/p90은 다음과 같다 (ms). 양쪽 32/32 counter가 유효했고 출력 readback 평균은 모두 `0.449135`, PASS였다.

| 경로 | MetalFX + fence 구간 | 전체 SR backend 구간 |
|---|---:|---:|
| in-process 직접 native | 2.4804 / 2.9178 | 2.5725 / 3.0336 |
| FFX→D3DMetal | 2.2479 / 2.3247 | 2.3373 / 2.4132 |

[직접 raw](evidence/2026-09-23-regression-fixes/sr-cost/inprocess-native-paired.stdout), [FFX raw](evidence/2026-09-23-regression-fixes/sr-cost/inprocess-ffx-paired.stdout), [빌드·입력 해시](evidence/2026-09-23-regression-fixes/sr-cost/inprocess-paired-build-inputs.txt), [실험 소스](evidence/2026-09-23-regression-fixes/sr-cost/inprocess-native-sr-probe.mm). 이 probe는 production 코드를 바꾸지 않는 임시 계측으로 실행했다. 처음 실행의 readback command 소유권 오류를 probe에서 고친 뒤 격리 prefix로 새로 얻은 결과만 표에 썼다.

**원인 귀속이나 성능 해결의 증거는 아니다.** 같은 프로세스·device/compiler지만 직접 경로는 별도 queue/allocator/command buffer와 caller texture를 사용했고, native-first 순차 실행이라 부하·스케줄링 드리프트를 통제하지 못했다. MetalFX counter 구간에는 optional fence 동기화도 포함되며 kernel-only 시간이 아니다. 앞선 별도 프로세스 1.09 대 3.30ms 차이를 불변의 번역 비용으로 해석하지 않는다. 이 결과로 production compiler, fence 순서, 기본 provider를 변경하지 않았다. 남은 게임 FPS·메모리 귀속에는 같은 장면/설정의 실제 게임 A/B와 queue·resource 조건을 한 변수씩 맞춘 관측이 필요하다. 현재 제공한 `YAAGL_FSR_UPSCALER=native`는 비교/우회 선택지이지 MetalFX 성능 수정이 아니다.
