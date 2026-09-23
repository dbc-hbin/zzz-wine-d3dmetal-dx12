# zzz-wine-d3dmetal-dx12

[English](README.md) | **한국어**

Apple Silicon의 **Yaagl ZZZ OS**에서 **젠레스 존 제로(Zenless Zone Zero, ZZZ)**를 **Direct3D 12(Apple GPTK 4.0b2)**로 실행하기 위한 Wine 11.17 런타임 소스와 원클릭 GUI 설치 프로그램입니다.

v1.1.0 공개 런타임은 그래픽 어댑터를 **AMD Radeon RX 9070**(`0x1002:0x7550`)으로 표시하고 게임의 FSR 업스케일링 API를 MetalFX로 번역합니다. DLSS 또는 NVIDIA NGX 번역 경로는 포함하지 않습니다. 설치 프로그램은 Yaagl Wine 메뉴에 **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**를 등록합니다.

**요구 환경은 Apple Silicon의 macOS 26.0 이상과 Rosetta 2입니다.** 모든 Mac에서 temporal upscaling은 시스템 기본 MetalFX 모델을 사용하며 BBR 또는 비공개 모델 버전을 강제하지 않습니다.

## 빠른 시작

1. [ZZZWineDX12Installer.zip](https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases/latest/download/ZZZWineDX12Installer.zip)을 다운로드합니다.
2. 압축을 풀고 **`ZZZ Wine DX12 Installer.app`**을 실행합니다.
3. Yaagl과 Wine 프로세스를 종료합니다. **`Yaagl Target`**에서 사용할 런처를 고른 뒤 **`Install Wine 11.17 ZZZ DX12`**를 선택합니다. 같은 런타임이 이미 선택돼 있으면 버튼이 **`Reinstall / Update Wine`**으로 표시됩니다.
4. 선택한 Yaagl 런처를 실행하고 Wine 메뉴에서 **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**를 선택합니다.

설치 프로그램은 Yaagl 앱과 지원 디렉터리를 감지하고, 동봉 아카이브를 설치하고, 런타임을 등록하며, Yaagl 리소스·Wine 선택·이전 런타임 디렉터리를 백업합니다. 아카이브는 Yaagl의 로컬 런타임 저장소에 남아 오프라인에서도 선택할 수 있습니다. Node.js는 필요하지 않습니다.

같은 이름의 런타임도 재설치할 수 있습니다. 이름이 같다는 이유로 현재 파일이라고 간주하지 않고 동봉 아카이브로 캐시와 런타임 디렉터리를 모두 교체합니다. 마지막 Wine 선택 활성화에 실패하면 최초 복원 백업을 소비하지 않고 이번 시도 직전의 런타임과 선택 상태로 되돌립니다. 여기서 “업데이트”는 실행한 설치 프로그램에 포함된 빌드로 교체한다는 뜻이며 온라인 업데이트 확인 기능이 아닙니다.

현재 설치기 소스에는 아직 기존 배포 ZIP에 포함되지 않은 DX12 마이그레이션이 있습니다. 구버전의 강제 DX12 실행 규칙이 확인되고, 같은 대상 D3DMetal 런타임이 선택돼 DX12를 지원하며, 저장된 DX12 설정이 없을 때만 ON을 저장해 v1.0.5의 실효 기본값을 보존합니다. 저장된 OFF는 덮어쓰지 않습니다. 새 런처와 이미 설정 기반인 런처는 기존 설정을 따르며, v1.1.x의 불명확한 설정 이력을 값만 보고 추측하지 않습니다.

### 터미널 설치

대상 선택 메뉴는 **Yaagl ZZZ OS**, **Yaagl ZZZ OS DX12 Beta**(글로벌), **Yaagl ZZZ DX12 Beta**(중국)를 지원하며 [DX12 베타 릴리즈](https://github.com/dbc-hbin/yaagl-ZZZ-DX12/releases)에도 설치할 수 있습니다. 각 대상은 별도의 `~/Library/Application Support/<런처 이름>` 폴더를 사용하므로 베타에 설치해도 일반판의 Wine은 교체하지 않습니다. Yaagl을 처음 설치했다면 한 번 실행해 지원 폴더를 만든 뒤 종료하고 설치 프로그램을 사용하세요. 일반판이 설치돼 있으면 기본 선택하며, 없으면 설치된 베타를 감지합니다.

CLI에서는 글로벌 베타에 `--app-path "/Applications/Yaagl ZZZ OS DX12 Beta.app"`, 중국 베타에 `--app-path "/Applications/Yaagl ZZZ DX12 Beta.app"`를 지정합니다. 알려진 앱 이름이면 대응하는 지원 폴더를 자동 선택하며, 사용자 지정 설치에서는 명시한 `--support-path`가 우선합니다.

```bash
./installer/zzz-wine-installer --install \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"

./installer/zzz-wine-installer --restore \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"
```

## v1.1.0 공개 런타임

### FSR 업스케일링 → MetalFX

- 실행 wrapper는 공개 그래픽 식별자를 AMD Radeon RX 9070(`0x1002:0x7550`)으로 고정합니다. NVIDIA 어댑터로 위장하지 않습니다. 현재 staging wrapper는 별도 helper 없이 FSR을 선택하고 Yaagl의 `MTL_HUD_ENABLED` 선택(미설정·빈 값 포함)을 보존합니다. 기존 v1.1.x 배포 archive에는 HUD를 강제로 켜는 구 helper가 남아 있으므로 새 런타임으로 교체해야 이 동작이 적용됩니다.
- builtin `amd_fidelityfx_upscaler_dx12` 모듈이 공개 FSR API 경계를 구현하고 허용된 temporal-upscaling 작업을 MetalFX로 번역합니다. AMD FSR4 신경망을 실행하지 않습니다.
- 새로 staging한 런타임에서는 `YAAGL_FSR_UPSCALER=metalfx`(미설정·빈 값도 기본값)가 builtin 업스케일러를, `YAAGL_FSR_UPSCALER=native`가 게임의 원본 canonical 업스케일러 DLL을 선택합니다. native 선택 시 builtin으로 fallback하지 않습니다. 이 명시적 SR 비교 옵션은 실행 wrapper를 통과하며 프레임 생성 provider 정책은 바꾸지 않습니다. 다른 값은 Wine 실행 전에 오류로 종료합니다. 기존 배포 archive에는 다시 빌드하기 전까지 반영되지 않습니다.
- Native AA와 Quality, Balanced, Performance, Ultra Performance 모드는 게임/provider가 명시적으로 선택합니다. 번역기가 임의로 품질 모드를 선택하지 않습니다. 요청이 MetalFX 최대 temporal 배율을 넘으면 MetalFX 출력을 하나의 균일 배율로 제한해 caller의 출력 텍스처 가운데에 배치하고 주변 texel은 보존합니다.
- 명시적인 OFF 선택은 게임 설정을 그대로 따릅니다. 런타임이 업스케일링이나 프레임 생성을 자동으로 켜지 않습니다.
- 새로 staging한 런타임은 출력 크기가 반복 변경될 때 FSR context당 비활성 temporal scaler를 최대 3개 보유합니다. 이전 크기로 돌아가면 temporal history를 reset합니다. 처음 보는 크기는 여전히 scaler를 생성하므로 MetalFX/driver가 계상하는 메모리가 증가할 수 있습니다.
- 모든 Mac에서 시스템 기본 MetalFX temporal 모델을 사용합니다. 하드웨어 이름 추정, BBR 강제 정책 또는 비공개 모델 버전 override는 없습니다.
- FSR exposure, reactive/composition mask, transfer function, sharpening, reset, jitter, motion-vector scale 및 활성 입출력 범위를 명시적으로 번역합니다. 잘못되거나 지원하지 않는 계약은 성공 no-op으로 처리하지 않고 오류를 반환합니다.

### 프레임 생성과 native fallback

- 자동 프레임 생성 provider는 실제 command-buffer mode와 Apple의 해당 mode 지원 검사를 통과할 때만 MetalFX interpolation을 선택합니다.
- 원본 FSR provider가 swapchain 생성·wrapping, presentation timing, pacing, 등록된 UI resource, custom present callback 및 위임된 swapchain query를 계속 소유합니다.
- 명시적인 native provider 선택은 native 경로를 유지합니다. 번역할 수 없는 입력은 MetalFX 작업을 기록하기 전에 원본 provider로 fallback합니다. MetalFX가 해당 frame의 작업을 기록한 뒤 오류가 발생해도 두 번째 native interpolation을 실행하지 않습니다.
- 패키지 런타임은 private 읽기 전용 native fallback을 절대 경로로 연결해 canonical DLL 재귀 로드를 막습니다. 원본 loader와 native fallback은 override하지 않습니다.
- 명시적인 OFF 상태는 그대로 꺼진 상태입니다. HUD label이 남았다는 사실만으로 프레임 생성이 계속됐다고 판단할 수 없습니다.
- 새로 staging한 런타임은 프레임 생성 presentation을 끄면 소비되지 않은 frame metadata를 비웁니다. 이미 기록된 GPU 작업은 완료까지 자체 resource를 보유합니다. ON에서 서로 다른 미완료 frame 설정은 최대 64개를 허용하며, 완료 콜백이 정리하기 전의 추가 설정은 HUD-less resource를 무한히 보유하는 대신 runtime error를 반환합니다.

### 번역 계약 상세

- 논리 D3D12 device는 raw COM tear-off 포인터 비교가 아니라 `ID3D12Device::GetAdapterLuid`로 식별합니다. command list와 모든 resource는 같은 adapter LUID를 보고해야 합니다. 이는 단일-adapter 런타임 검증이며 실제 multi-adapter 하드웨어 검증은 아닙니다.
- 현재 활성 입력/출력보다 큰 backing texture를 허용합니다. MetalFX에는 활성 크기와 일치하는 resource를 전달하고 필요한 경우에만 GPU staging을 사용하며 caller의 활성 출력 영역 밖 texel은 보존합니다. 저해상도와 출력 해상도 motion vector 모두 같은 규칙을 따릅니다.
- Prepare V1은 camera 정보를 생략하거나 단일 optional camera extension으로 제공할 수 있고 V2는 camera 정보를 직접 포함합니다. frame ID가 연속적이지 않거나 reset이 명시되면 history를 reset합니다. generation rectangle은 signed 좌표를 유지하며 width와 height가 모두 0일 때만 full display이고 partial rectangle의 좌상단은 depth/motion 좌표 (0,0)에 대응합니다.
- 프레임 생성 Prepare는 고정 SDK의 camera 기본값 처리를 따릅니다. 유한한 `viewSpaceToMetersFactor ≤ 0`은 배율 `1.0`으로 처리하고 context 생성 시 무한 깊이를 선택했다면 `cameraFar`는 검사하지 않습니다. 유한 깊이 모드의 두 plane은 양수·유한·서로 다른 값이어야 하며 min/max로 순서를 정규화합니다. reversed depth는 별도 flag로 유지하므로 `cameraNear=5000`, `cameraFar=0.1`도 depth texture를 반전하지 않고 처리합니다. 유한하지 않은 scale은 계속 거부합니다.
- sRGB, PQ, scRGB transfer는 정의된 luminance 변환을 보존하고 유한하지 않거나 잘못된 범위는 거부합니다. sharpening이 꺼져 있으면 `[0,1]` 범위의 유한한 sharpness가 남아 있어도 RCAS 없이 처리합니다. jitter phase query는 고정 SDK처럼 소수부를 버리고(1600→2000은 12), null dispatch descriptor는 `FFX_API_RETURN_ERROR_PARAMETER`를 반환합니다.
- distortion field, AMD debug shader view와 tear/reset overlay, custom DX12 backend allocation callback, frame당 2개 이상의 generated output은 지원하지 않으며 오류를 반환합니다.
- Metal4 compute parameter buffer는 encode 전에 residency에 포함합니다. configuration cache는 최대 8개이며 luminance·rectangle 원점 변경은 factory 재생성 없이 history를 reset하고, cache에서 제거된 configuration도 진행 중 작업이 완료될 때까지 보존합니다.
- swapchain에 알리는 Configure 호출은 앱 callback과 user context가 같으면 불변 binding을 재사용해 불필요한 present drain을 피합니다. 실제 callback 변경 시에는 native swapchain을 통해 이전 binding을 회수하며 일반 Configure 호출 중 처리 대기 중인 frame별 HUD-less snapshot을 보존합니다. 이는 pacing·수명 관리 수정이지 측정된 FPS나 화질 개선을 뜻하지 않습니다.

### 프레임 생성 검증 경계

아래 항목은 아직 검증하지 않은 위험입니다. 이 항목들이 닫히기 전까지 이 경로는 FPS나 화질을 보장하지 않습니다.

- 현재 합성 검증은 균일한 depth와 하나의 global motion vector를 사용합니다. disocclusion이나 전경/배경의 혼합 motion은 다루지 않으며, 게임에서 관찰된 2256×1272 render-resolution motion vector가 3840×2160 출력으로 전달되는 조건도 재현하지 않습니다.
- 현재 depth와 motion vector는 보간 전에 nearest sampling으로 확대합니다. 이 방식과 MetalFX에 native 저해상도 입력을 직접 주는 방식 중 어느 쪽이 나은지는 A/B 비교가 필요하며, 알려진 화질 버그로 확정된 것은 아닙니다.
- descriptor의 nullable `scaler`는 연결하지 않습니다. Apple WWDC25 session 211 샘플은 scaler를 연결하지만, 이는 아키텍처 차이일 뿐 현재 경로의 화질 결함을 입증하지 않습니다.
- 입력 color가 이미 temporal upscale된 경우 jitter 단위는 아직 확인되지 않았습니다. 근거 없이 jitter를 재배율하거나 0으로 바꾸지 말고, 먼저 producer가 실제로 사용하는 규약을 캡처한 뒤 시간적으로 안정된 장면에서 비교해야 합니다.
- 4K에서 RGBA16F, R32F, RG16F texture 크기로 계산한 Generate 1회당 논리적 scratch 할당량은 UI 없을 때 약 190 MiB, UI가 있을 때 약 253 MiB입니다. 이는 논리적 할당 크기이며 측정된 resident memory, bandwidth, latency 또는 frame-time 비용이 아닙니다.
- generation과 생성 프레임 present 로그는 각각 callback 120회에서 중단되며 게임 frame 120개를 뜻하지 않습니다. OFF 전환이나 그 이후 생성 중단을 기록하지 않으므로 이를 입증할 수 없습니다.

다음 검증은 2256×1272→3840×2160 조건에서 disocclusion과 혼합 motion이 있는 게임 캡처, nearest 확대 입력과 native 저해상도 depth/MV 입력의 A/B 비교, 실제 jitter 규약 기록, resident memory 및 GPU 시간 profiling, callback 로그 제한 이후에도 OFF 전환과 후속 생성 동작을 명시적으로 관찰하는 과정을 포함해야 합니다.

### 선택적 제한 로그

`YAAGL_FSR_LOG`는 선택 사항이며 절대 경로를 지정해야 합니다.

- 업스케일링은 lifecycle/query/error event와 성공한 dispatch metadata를 전역 dispatch ID 1~120에 대해서만 기록합니다. 실패 frame 상세 기록은 별도로 최대 120회입니다.
- 프레임 생성은 `YAAGL_FSR_LOG`에 `first_encode` JSON record를 한 번 기록합니다. stderr의 프레임 생성 실패 기록은 120회에서 중단합니다.
- 선택적 `WINEDEBUG=trace+yaagl_fsr_fg` 채널은 generation과 생성 프레임 present callback 결과를 각각 120회까지만 기록합니다.
- 정상 상태에서 무제한 frame별 로그를 남기지 않습니다.
- 로그는 API, encode 또는 callback 진행을 나타냅니다. GPU 완료, 화질, FPS 또는 OFF 전환의 증거가 아닙니다.

제거한 DLSS 전용 경로는 숨겨진 호환 옵션으로 남아 있지 않습니다. production bridge와 build inventory에는 NGX 진입 hook, NGX reprojection helper·smoke fixture, DLSS exposure 보정, temporal interception 또는 기존 frame-probe 구현·제어가 포함되지 않습니다. FSR에 필요한 공용 command-replay hook 두 개는 `d3dmetal-replay-hooks.{hpp,mm}`로 분리했습니다. layout v9는 PSO/cache hook 17개와 이 replay hook 두 개를 포함하며 DLSS 번역을 복구하지 않습니다.

**미배포 소스:** layout v10은 GPU 완료 시 회수를 위한 Metal4 queue-commit hook을 추가합니다. dispatch table은 20개 항목(PSO/cache 17개, replay 2개, commit 1개)이며 대응하는 D3DMetal patch와 native sidecar를 함께 다시 빌드해야 합니다. 기존 배포 archive는 변경하지 않았습니다.

현재 소스는 완료된 execution lease를 allocator Reset 전에 회수하되, 미제출 작업이나 callback 등록 실패에서는 owner의 안전한 보유를 유지합니다. SR은 더 작은 active input에서 호환되는 scaler capacity를 재사용하며 history reset과 동기화된 edge staging을 수행합니다. [메모리 측정 결과와 한계](docs/screenshot-sr-analysis-2026-09-23.ko.md)는 bounded reuse와 즉시 물리 메모리 반환, 아직 검증하지 않은 게임 전체 메모리 차이를 구분합니다.

### 검증 상태

macOS 27 / Apple M5 Pro에서 다음을 확인했습니다.

- **v1.1.1은 등록 실패를 수정했습니다.** 이 설치기가 이미 등록한 Yaagl frontend인데 hash 기반 복원 백업이 사라진 경우 “changed without a matching backup”으로 거부되던 문제입니다. 이제 등록 시 해당 frontend에서 이 설치기 자신의 updater hook과 catalog 항목만 제거해 marker 없는 복원 기준을 복구하며, 무관한 catalog 항목·frontend 버전·local-archive 설치 경로는 유지합니다. 인식할 수 없거나 변조된 hook은 frontend를 건드리지 않고 그대로 실패합니다. Wine 런타임 바이트는 v1.1.0과 동일합니다.
- 보고된 상태의 사본으로 재현했습니다. v1.1.0 helper는 보고된 메시지와 함께 종료 코드 1로 실패하고 아무것도 바꾸지 않았고, v1.1.1 helper는 완료해 복구 기준을 기록하면서 등록된 frontend를 바이트 그대로 유지했습니다. 이미 등록된 바이트를 다시 등록해도 변화가 없으며, hook 인자를 변조하면 여전히 종료 코드 1로 실패하고 frontend는 보존됩니다.
- 최종 전체 런타임 아카이브를 다시 추출해 Metal4와 legacy command-buffer 양쪽에서 FSR 업스케일링·프레임 생성 GPU 검사를 통과했습니다. 이 검사에는 Metal API Validation을 활성화했습니다.
- 일반 실행 환경에서 DX12 그래픽·컴퓨트·레이 트레이싱 GPU readback을 통과했습니다. direct/indirect draw, blending, logic operation, MSAA 및 동일·상이 descriptor의 독립 D3D12 객체를 포함합니다.
- MetalFX backend, quality, transport, legacy-transport 네이티브 suite를 통과했습니다. 네이티브 cache/stage-cache/key 검사는 graphics·compute·RT key 경로의 single-flight와 객체 재사용을 확인했습니다. production hit counter는 노출되지 않으며 측정했다고 주장하지 않습니다. production launcher의 실제 DXGI 열거 결과는 `0x1002:0x7550`, **AMD Radeon RX 9070**이었습니다.
- core/backend 아카이브를 재조립한 결과 파일 목록·바이트·모드·symlink가 staging과 일치했습니다. 서명과 격리된 Wine 초기화도 통과했습니다. 선언된 tuned Wine core 산출물 45개는 검증된 v1.0.5 base와 바이트가 같으며 FSR/native overlay를 새로 빌드했습니다.
- v1.1.0 설치 ZIP을 다시 추출해 deep/strict 서명을 확인하고 실제 보존한 v1.0.5 아카이브로 설치·업데이트·복원·활성화 실패 시나리오 9개를 통과했습니다. DX12 실행 인자 회귀 3개와 경로를 옮긴 FSR launcher 회귀도 통과했습니다.
- v1.1.1 설치 ZIP은 deep/strict 서명을 통과했고, 변경되지 않은 v1.1.0 런타임을 포함하며, 백업 유실 복구 시나리오를 포함한 리소스 수명주기 10개 시나리오를 모두 통과했습니다.
- 커서 소유권·RawInput 소스 harness와 격리된 Win32 cold-start/layered-window 커서 metadata 검사를 통과했습니다. 네이티브 커서 픽셀이나 물리 RawInput을 측정한 결과는 아닙니다.

**한계:** macOS 26 실기기 실행, 네이티브 커서 픽셀, 첫 물리 RawInput delta는 미검증입니다. Apple 원본 `libdxccontainer.dylib`는 변경하지 않았으며 최소 버전 26.4를 기록합니다. 선택적 Metal API Validation을 켠 generic MSAA resolve 대조 검사에서는 원본 v1.0.5와 v1.1.0 모두 동일한 render-target-usage assertion이 발생합니다. 이 기존 validation 제약을 수정했다고 주장하지 않으며 일반 실행 환경의 GPU readback은 통과했습니다. 위의 프레임 생성 화질·성능 검증 한계도 그대로 적용됩니다.

## 이전 릴리스 기록

### v1.0.5: 커서·RawInput 런타임 재빌드와 동일 이름 업그레이드

- v1.0.5는 커서 소유권·RawInput 분리 수정을 포함해 새 빌드 디렉터리에서 Wine 산출물 45개를 재빌드했습니다. 네이티브 모듈 7개는 SDK 26.5로 macOS 26.0을 타깃으로 빌드했고, 나머지 Wine 파일은 고정된 P3 패키지에서 가져왔습니다. 다른 tuned 패치, 네이티브 PSO 캐시와 `D3DM_MTL4=1`은 변경하지 않았습니다.
- D3DMetal의 DXIL 컨테이너 분석과 DXBC/HLSL 변환에 필요한 Apple 원본 `libdxccontainer.dylib`는 기록된 최소 버전 26.4를 포함해 바이트 그대로 유지했습니다. 조사한 import에서 26.4 전용 API는 발견되지 않았습니다. Wine 설정과 격리된 DX12 그래픽·컴퓨트·레이 트레이싱 GPU readback은 macOS 27에서 통과했으며 macOS 26 실기기 실행은 검증하지 않았습니다.
- 동봉 Wine에는 `db45a95`를 실제 빌드해 넣었습니다. 커서 소유권 동기화가 포인터 좌표를 바꾸지 않으며 보정된 RawInput 이동량은 별도로 전달했습니다. Wine 클라이언트·서버 모듈은 프로토콜 **966**으로 함께 재빌드했습니다.
- Wine 메뉴 이름과 런타임 ID를 유지했습니다. v1.0.5 설치기는 다른 Wine catalog 항목을 보존하면서 같은 이름의 기존 런타임과 캐시 아카이브를 새 빌드로 교체했습니다.
- 최종 선택 활성화에 실패하면 최초 복원 백업을 소비하지 않고 이번 설치 시도 직전의 런타임과 선택 상태로 되돌렸습니다.
- 배포 ZIP을 풀어 설치·업데이트·복원 시나리오 9개와 DX12 실행 인자 검사 3개를 통과했습니다. 이전 프로토콜 965 아카이브에서 업그레이드해 네이티브 모듈 4개(`wineserver`, `ntdll`, `winemac`, `win32u`)의 교체도 확인했습니다.
- 격리된 Wine 창에서 cold-start cursor request, layered-window ownership 및 Esc 이후 capture transition을 실행했습니다. 이 capture는 macOS native activation이나 custom cursor pixel을 확인하지 못했습니다. 합성 포인터 입력으로는 물리 RawInput callback이 발생하지 않아 native cursor pixel과 첫 물리 마우스 이동량은 미검증으로 남았습니다.
- 기존 game cursor 수정은 유지됐습니다. 소스 수준의 arrow setter 호출만으로 의도하지 않은 native cursor overwrite를 입증할 수 없어 이전 native-overlay P2 판정은 철회했습니다.

### v1.0.4: DX12 실행 인자 전달

- v1.0.4는 선택한 배포판 식별자를 실제 Wine runner에 유지하고 **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**에만 `-use-d3d12`를 추가했습니다. 이전 설치기는 실행 객체에 없는 `id`를 검사해 패치가 적용돼도 인자를 빠뜨릴 수 있었습니다.
- 일반 실행과 Steam patch 실행 모두에 게임 인자를 전달했습니다. 다른 D3DMetal Wine에는 DX12를 강제하지 않았습니다.
- 이전 ID 조건과 backend 전체 대상 조건을 범위가 제한된 조건으로 교체했으며 반복 설치해도 인자가 중복되지 않았습니다.
- 이 수정에는 Wine 아카이브만이 아니라 설치 프로그램과 update helper가 필요했습니다. v1.0.4는 v1.0.2/v1.0.3 아카이브를 유지했고 v1.0.5에서 커서·RawInput 재빌드 런타임으로 교체했습니다. 이 릴리스들의 Tahoe 실기기 DX12 실행은 검증하지 않았습니다.

### v1.0.3: launcher update와 복원

v1.0.3은 설치 프로그램만 변경했고 macOS 26 Wine 아카이브와 tuning은 v1.0.2와 같았습니다.

- 앱 번들이 아니라 Yaagl 데이터 디렉터리의 실행용 `resources.neu`를 patch했습니다. 앱 리소스와 기존 앱 백업은 건드리지 않았습니다.
- `.zzz-wine-registration`의 native helper가 다운로드된 앱 내부 update에 Wine을 등록한 뒤 활성 frontend를 교체했습니다. 설치 또는 앱 내부 update 때만 실행되며 background service나 Node.js는 필요하지 않았습니다.
- 복원은 오래된 전체 리소스 백업이 아니라 현재 등록 generation과 짝이 맞는 pristine resource를 사용했습니다.

구버전 설치기로 Yaagl이 downgrade됐다면 원하는 버전으로 Yaagl을 update하고 종료한 뒤 현재 설치 프로그램을 실행하세요. 앱 전체 교체나 외부에서의 resource 교체는 앱 내부 hook을 우회할 수 있으므로 그런 변경 후에는 설치 프로그램을 다시 실행하세요.

## 주요 런타임 구성

1. **Direct3D 12와 GPTK 4.0b2** — D3DMetal과 Metal IR이 Direct3D 12 rendering을 Metal로 변환합니다.
2. **Native ARM64 wineserver** — server를 Rosetta로 실행하지 않아 synchronization과 IPC overhead를 줄입니다.
3. **MSync fast path** — Windows synchronization primitive를 overhead가 낮은 macOS mechanism에 연결합니다.
4. **Native PSO cache** — shader compile 중복을 제거하고 device lifetime 동안 compile된 pipeline state object를 유지합니다.
5. **Cursor ownership과 RawInput 분리** — ownership synchronization과 pointer coordinate를 분리하고 보정한 motion delta를 별도로 전달합니다.
6. **Media·audio·window·resource tuning** — 저장소의 GStreamer, Media Foundation, CoreAudio, window 및 network patch를 유지합니다.

## 저장소 구조

```text
zzz-wine-d3dmetal-dx12/
├── dlls/                   # FSR upscaler/FG builtin을 포함한 Wine source
├── d3dmetal-pso-cache/     # Native PSO cache와 FSR → MetalFX backend
├── external/               # 로컬 GPTK framework 입력
├── include/                # Wine/FSR bridge 공용 header
├── installer/              # SwiftUI installer와 CLI source
├── patches/                # Wine tuned/P3 patch series
├── scripts/                # Build, verification, staging, packaging tool
└── server/                 # Native wineserver와 MSync 구현
```

## 소스에서 빌드

### 요구 환경

- Apple Silicon의 macOS 26.0 이상, Rosetta 2 및 macOS 26 SDK
- Xcode Command Line Tools
- LLVM MinGW toolchain
- Bison, pkg-config 및 GStreamer dependency
- 준비된 P3 source/host/dependency/provenance 입력, 로컬 GPTK overlay 및 Steam helper payload. 이 저장소는 해당 외부 입력을 다운로드하지 않습니다.

### 런타임과 설치 프로그램

```bash
export WINE_P3_ROOT="/absolute/path/to/prepared/wine-p3"
export YAAGL_STEAM_HELPER_DIR="/absolute/path/to/protonextras"
export GPTK_SOURCE="/absolute/path/to/gptk-overlay/wine"
export MACOSX_DEPLOYMENT_TARGET=26.0
export SDKROOT="/path/to/MacOSX26.sdk"
export WINE_PACKAGE_NAME=wine-11.17-zzz-dx12-gptk4b2-macos26
export WINE_RUNTIME_ID=11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server

./scripts/build-wine-tuned.sh all
./scripts/package-wine-p3-runtime.sh build/wine-tuned/host "$GPTK_SOURCE" \
  build/wine-tuned/provenance.json build/wine-tuned/package
./installer/build.sh
```

### 업스트림 Yaagl 연동

[Yaagl PR #759](https://github.com/yaagl/yet-another-anime-game-launcher/pull/759) 연동은 split 쌍을 사용합니다. Yaagl이 backend를 별도로 다운로드·캐시하고 Wine 초기화 전에 추출한 core의 `wine/` 디렉터리에 설치합니다. 두 패키지는 짝을 이룬 조합이며 임의의 Wine·backend 호환성을 보장하지 않습니다. all-in-one 아카이브와 GUI 설치 프로그램이 계속 지원되는 자체 완결 경로입니다. 업스트림 연동에서 ZZZ DirectX 12 옵션은 기본 꺼짐이며 `supportsD3d12`를 선언한 배포판에서만 활성화됩니다.

### v1.1.0 릴리스 asset

v1.1.1은 v1.1.0 런타임을 그대로 다시 게시하며 `ZZZWineDX12Installer.zip`만 변경됩니다. 따라서 아래 런타임 아카이브 이름이 v1.1.1 릴리스에서도 그대로 사용됩니다.

|Asset|내용|
|---|---|
|`ZZZWineDX12Installer.zip`|GUI 설치 프로그램과 아래 full runtime 아카이브|
|`wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz`|all-in-one 런타임(`wine/` 루트)|
|`wine-11.17-zzz-core-macos26.tar.xz`|split core 아카이브(`wine/` 루트)|
|`d3dmetal-gptk4b2-zzz-v1.1.0.tar.xz`|split backend 오버레이(상대 경로 `lib/`)|

각 아카이브에는 `.sha256` sidecar가 함께 제공됩니다. `installer/build.sh`는 기본적으로 `build/release-v1.1.1/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz`의 full runtime 아카이브를 읽습니다(`RUNTIME_ARCHIVE_SOURCE`로 변경 가능).

```bash
# 현재 소스로 staging할 출력 경로와 검증된 빌드 입력을 지정합니다.
WINE_ROOT=/absolute/path/to/current-stage/wine
PATCHED_D3DMETAL=/absolute/path/to/patched-D3DMetal
NATIVE_BUILD=/absolute/path/to/native-build
OUTPUT_DIR=/absolute/path/to/split-output
(
  set -e
  base_tmp=$(mktemp -d)
  trap 'rm -rf -- "$base_tmp"' EXIT
  tar -xJf build/release-v1.1.0/v1.0.5-original-runtime.tar.xz -C "$base_tmp"

  # 구 full v1.1.0 아카이브가 아니라 추출한 v1.0.5 baseline에서 staging합니다.
  python3 scripts/stage-runtime.py --wine-source "$base_tmp/wine" --wine-dest "$WINE_ROOT" \
    --patched-d3dmetal "$PATCHED_D3DMETAL" --build-dir "$NATIVE_BUILD" --play --fsr-translator

  # 최종 staging byte에 맞게 상속된 P3 metadata를 갱신합니다.
  python3 scripts/refresh-staged-runtime-metadata.py \
    --tree "$WINE_ROOT" --base "$base_tmp/wine" \
    --native-manifest "$NATIVE_BUILD/build-manifest.json"

  # split 패키징은 schema 4 staging을 현재 소스와 대조해 검증합니다.
  # 보존된 구 full v1.1.0 아카이브는 schema 3이므로 패키징 입력이 아닙니다.
  sh scripts/package-wine-runtime-split.sh "$WINE_ROOT" "$OUTPUT_DIR"
)
```

정확한 아카이브 hash는 상위 릴리스 노트에 기록하며 이 문서에서는 주장하지 않습니다.

### 범위가 제한된 검사

```bash
python3 scripts/test-metalfx-native.py --out <native-evidence>
python3 scripts/test-fsr-launch-profile.py
python3 scripts/test-fsr-translator.py --runtime <runtime> --out <upscaler-evidence>
python3 scripts/test-fsr-translator.py --frame-generation --command-buffer metal4 \
  --runtime <runtime> --out <fg-metal4-evidence>
python3 scripts/test-fsr-translator.py --frame-generation --command-buffer legacy \
  --runtime <runtime> --out <fg-legacy-evidence>
node --test scripts/test-dx12-launch-regression.mjs
```

`scripts/test-metalfx-native.py`는 native suite를 실행하며 `transport` suite를 선택할 때 `--d3dmetal <검증된 D3DMetal 바이너리>`가 필요합니다. `scripts/test-fsr-translator.py`는 `--runtime`으로 지정한 런타임에 대해 DX12 fixture를 컴파일·실행합니다.

이 명령은 범위가 제한된 검사 방법을 설명할 뿐 최종 릴리스 산출물이 통과했다는 주장이 아닙니다.

## 라이선스

- Wine 소스 코드는 **GNU Lesser General Public License(LGPL v2.1+)**를 따릅니다.
- D3DMetal bridge 구성 요소와 설치 프로그램 도구에는 이 저장소에 포함된 조건이 적용됩니다.
- `d3dmetal-pso-cache/third-party/fidelityfx/`에 포함된 FidelityFX SDK header는 AMD의 MIT license 본문과 copyright 고지를 그대로 유지합니다.
