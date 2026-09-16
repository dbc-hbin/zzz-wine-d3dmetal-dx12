# zzz-wine-d3dmetal-dx12

[English](README.md) | **한국어**

macOS(Apple Silicon) 환경의 **Yaagl ZZZ OS**에서 **젠레스 존 제로(Zenless Zone Zero, ZZZ)**를 **Direct3D 12 (GPTK 4.0b2)**로 가장 부드럽고 안정적으로 구동하기 위한 Wine 11.17 최적화 런타임 소스 및 간편 설치 프로그램입니다.

설치 프로그램은 포함된 사전 빌드 Wine 패키지를 설치하고 Yaagl Wine 메뉴에 **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**를 등록합니다.

**배포 타깃은 Apple Silicon의 macOS 26.0 이상이며 Rosetta 2가 필요합니다.** v1.0.5는 커서 소유권·RawInput 분리 수정을 포함해 새 빌드 디렉터리에서 Wine 산출물 45개를 재빌드했습니다. 그중 네이티브 모듈 7개는 SDK 26.5로 macOS 26.0을 타깃으로 빌드했으며, 나머지 Wine 파일은 고정된 P3 패키지를 계승합니다. 다른 Tuned 패치, 네이티브 PSO 캐시, `D3DM_MTL4=1`은 유지됩니다.

`libdxccontainer.dylib`는 D3DMetal의 DXIL 컨테이너 분석과 DXBC/HLSL 변환에 필요합니다. 기록된 최소 버전 26.4를 포함해 Apple 원본 바이너리를 그대로 유지했으며, 조사한 import에서 26.4 전용 API는 발견되지 않았습니다. Wine 설정 배치와 DX12 그래픽·컴퓨트·레이 트레이싱 GPU 읽기 검증은 macOS 27에서 통과했습니다. **macOS 26 실기기 실행은 아직 검증하지 않았습니다.**

---

## ⚡ 빠른 시작 (GUI 간편 설치)

일반 사용자분들은 별도의 복잡한 빌드 과정 없이, 포함된 **GUI 설치 프로그램**으로 Yaagl ZZZ OS에 적용할 수 있습니다.

### 방법 1: GUI 앱으로 설치
1. [ZZZWineDX12Installer.zip](https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases/latest/download/ZZZWineDX12Installer.zip)을 다운로드하고 압축을 풉니다.
2. **`ZZZ Wine DX12 Installer.app`**을 실행합니다.
3. Yaagl ZZZ OS 앱 및 데이터 경로가 자동으로 감지됩니다.
4. Yaagl ZZZ OS를 종료한 후 **`Install Wine 11.17 ZZZ DX12`** 버튼을 누릅니다. 해당 Wine이 이미 선택돼 있으면 **`Reinstall / Update Wine`**으로 표시됩니다.
   - 포함된 사전 빌드 Wine 런타임 아카이브를 Yaagl에 설치합니다.
   - Yaagl Wine 메뉴에 **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**를 등록합니다.
   - Yaagl의 리소스, Wine 선택 및 Wine 디렉터리를 백업하여 기존 구성을 복원할 수 있습니다.
5. Yaagl ZZZ OS를 열고 Wine 메뉴에서 설치된 Wine 런타임을 선택해 게임을 시작합니다.

포함된 아카이브는 Yaagl의 로컬 런타임 저장소에 유지되므로, 오프라인에서도 Yaagl Wine 메뉴에서 이 Wine 런타임을 선택하거나 다른 Wine 런타임으로 전환할 수 있습니다. 설치 프로그램은 Node.js를 필요로 하지 않습니다.

**같은 이름·같은 ID의 Wine도 재설치할 수 있습니다.** 새 설치 프로그램의 동봉 아카이브로 로컬 캐시와 Wine 디렉터리를 교체하며, 이름이 같다는 이유로 건너뛰지 않습니다. 구버전 파일을 남기는 덮어쓰기 방식이 아닙니다. 마지막 Wine 선택 상태 저장에 실패하면 이번 설치 직전의 런타임과 선택 상태를 복원하고, 기존의 최초 복원용 백업은 유지합니다. 여기서 업데이트는 **실행한 설치 프로그램에 포함된 빌드로 교체**한다는 뜻이며, 온라인 최신 Wine을 자동 조회하는 기능은 아닙니다.

### 업스트림 Yaagl용 분리 패키지

[Yaagl PR #759](https://github.com/yaagl/yet-another-anime-game-launcher/pull/759)는 v1.0.5의 `wine-11.17-zzz-core-macos26.tar.xz`(`wine/` 루트)와 `d3dmetal-gptk4b2-zzz-v1.0.5.tar.xz`(상대 경로 `lib/` 오버레이)를 사용합니다. Yaagl이 백엔드를 별도로 다운로드·캐시하고 Wine 초기화 전에 Wine 디렉터리에 설치합니다. 두 패키지는 호환성을 확인한 한 쌍이며, 임의의 Wine·백엔드 조합을 보장하지 않습니다. 기존 통합 압축과 GUI 설치기는 변경하지 않았습니다.

검증된 스테이징 런타임에서 `bash scripts/package-wine-runtime-split.sh`로 분리 패키지를 재생성할 수 있습니다. 컴파일된 바이트·권한·심볼릭 링크를 보존하고, 재조립·서명과 임시 prefix의 Wine 초기화를 검증합니다. 업스트림 연동의 ZZZ DirectX 12 옵션은 기본 꺼짐이며, `supportsD3d12`를 선언한 배포판에서만 활성화됩니다.

### v1.0.5: 커서·RawInput 런타임 재빌드와 동일 이름 업그레이드

- 동봉 Wine에 `db45a95`를 실제 빌드해 넣었습니다. 커서 소유권 동기화가 포인터 좌표를 바꾸지 않으며, 보정된 RawInput 이동량은 별도로 전달합니다. Wine 클라이언트·서버 모듈을 프로토콜 **966**으로 함께 재빌드했습니다.
- Wine 메뉴 이름과 런타임 ID는 유지합니다. Yaagl과 해당 Wine·게임 프로세스를 종료한 뒤 v1.0.5 설치기를 실행하면, 같은 이름의 기존 런타임과 캐시 아카이브도 새 빌드로 교체합니다.
- 이전 D3DMetal 빌드를 포함한 다른 Wine 메뉴 항목을 보존합니다. 최종 선택 활성화에 실패하면 최초 복원 백업을 소비하지 않고 이번 설치 직전의 런타임·선택 상태로 되돌립니다.
- 배포 ZIP을 풀어 설치·업데이트·복원 시나리오 9개와 DX12 실행 인자 검사 3개를 통과했습니다. 실제 이전 프로토콜 965 아카이브에서 업그레이드해 네이티브 모듈 4개(`wineserver`, `ntdll`, `winemac`, `win32u`)의 교체도 확인했습니다.
- 최종 아카이브의 격리 D3D12 그래픽·컴퓨트·레이 트레이싱 GPU 읽기 검증은 macOS 27에서 통과했습니다. 실제 격리 Wine 창에서 콜드 스타트 커서 요청, 레이어드 창 소유권, Esc 이후 캡처 전환을 실행했습니다. 커서 캡처에서는 macOS 네이티브 활성 상태와 사용자 지정 커서 픽셀을 확인하지 못했으므로, 첫 네이티브 활성화의 픽셀 검증 통과나 커서 비표시 회귀로 판정하지 않았습니다. 합성 포인터 입력으로는 물리 RawInput 콜백이 발생하지 않아 네이티브 커서 픽셀과 첫 물리 마우스 이동량은 미검증입니다.
- macOS 화살표 대신 게임 커서를 표시하도록 한 기존 수정은 v1.0.5에도 유지됩니다. 앞서 제시한 네이티브 오버레이 P2 판정은 철회합니다. 소스 수준의 화살표 설정 호출만으로 실제 네이티브 커서를 잘못 덮어쓰는 결함을 입증하지 못했습니다.

### v1.0.4: DX12 실행 인자 전달 수정

- 선택한 Wine의 식별자를 실제 실행 객체에도 유지해, **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`를 선택했을 때만** `-use-d3d12`를 추가합니다. 이전 설치기는 실행 객체에 없는 `id`를 검사해 패치가 적용돼도 인자를 추가하지 못했습니다.
- 일반 실행뿐 아니라 Steam 패치 실행 경로에도 게임 인자를 전달합니다. 다른 D3DMetal Wine에는 DX12를 강제하지 않습니다.
- 이전 ID 조건 패치와 로컬의 D3DMetal 전체 대상 패치를 새 조건으로 교체하며, 반복 설치해도 인자가 중복되지 않습니다.

**최신 설치기에 이 런처 수정이 포함돼 있으며, Wine 아카이브만 교체해서는 적용되지 않습니다.** v1.0.4는 설치 프로그램과 업데이트 helper만 재빌드하고 v1.0.2/v1.0.3 Wine 아카이브를 유지했습니다. v1.0.5부터 커서·RawInput 수정을 빌드한 새 아카이브로 교체합니다. Tahoe 실기기 DX12 검증은 아직 수행하지 않았습니다.

### v1.0.3: 런처 업데이트와 복원

v1.0.3은 설치 프로그램만 수정합니다. 동봉된 macOS 26 Wine 아카이브와 튜닝은 v1.0.2와 동일합니다.

- 앱 번들이 아니라 Yaagl 데이터 폴더의 실행용 `resources.neu`만 등록합니다. 앱 리소스와 기존 앱 백업은 건드리지 않으며, 시작 동기화가 구버전 앱 리소스로 실행용 리소스를 덮어쓰지 않도록 합니다.
- `.zzz-wine-registration`의 네이티브 helper가 앱 내부 업데이트의 다운로드 파일을 교체하기 전에 Wine을 등록합니다. 설치·업데이트 때만 실행되며 백그라운드 서비스나 Node.js는 필요하지 않습니다. 지원하지 않는 프런트엔드 구조나 helper 오류는 기존 리소스 교체 전에 업데이트를 중단합니다.
- 복원은 현재 등록된 리소스와 짝이 맞는 원본을 사용하며, 오래된 전체 리소스 백업으로 되돌리지 않습니다. 다음 업데이트를 준비해도 현재 리소스의 복원 지점은 유지됩니다.

이전 설치기로 Yaagl이 이미 다운그레이드됐다면 먼저 Yaagl을 원하는 버전으로 업데이트하고 종료한 뒤 최신 설치 프로그램으로 설치하세요. 앱 전체 교체나 외부에서의 리소스 교체는 앱 내부 업데이트 hook을 우회할 수 있으므로, 그런 변경 후에는 설치기를 다시 실행하세요.

### 방법 2: 터미널 CLI로 설치
```bash
./installer/zzz-wine-installer --install \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"

# 이전 Wine 디렉터리 복원
./installer/zzz-wine-installer --restore \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"
```

---

## 🚀 적용된 최적화 및 패치 안내

이 빌드는 순정 Wine 11.17에 ZZZ 및 macOS 환경에 특화된 여러 최적화 패치를 통합한 버전입니다.

### 1. Direct3D 12 & Apple GPTK 4.0b2 완벽 대응
- Apple Game Porting Toolkit 4.0b2의 최신 D3DMetal 및 Metal IR 변환 계층을 통합했습니다.
- ZZZ의 고품질 DirectX 12 렌더링 호출을 Apple Silicon의 Metal API로 빠르고 정확하게 변환합니다.

### 2. Apple Silicon 네이티브 ARM64 Wineserver (`0002-native-x86-server.patch`)
- 기존 x86_64 Wine은 프로세스를 총괄하는 `wineserver`까지 Rosetta 2 에뮬레이션으로 동작하여 불필요한 지연이 발생했습니다.
- 이 빌드는 `wineserver`를 Apple Silicon(ARM64) 네이티브로 빌드하여 실행하므로, 윈도우 스레드 관리와 IPC 시스템 호출 오버헤드가 크게 단축됩니다.

### 3. 고성능 MSync 동기화 패치 (`0001`, `0003`, `0007`, `0012`)
- Windows의 동기화 객체(뮤텍스, 이벤트, 세마포어)를 macOS 커널의 빠른 Mach 세마포어와 공유 메모리에 직결했습니다.
- 멀티스레드 렌더링 환경에서 스레드가 대기할 때 커널 전환 비용을 최소화하여 프레임 드랍과 끊김 현상을 방지합니다.

### 4. 네이티브 Metal PSO 캐시 및 캐시 웜업 (`libYaaglNativePsoCache`)
- 게임 플레이 중 새로운 셰이더를 처음 만날 때 발생하는 **미세 끊김(Micro-stuttering)**을 잡기 위한 전용 네이티브 캐시 계층입니다.
- 중복 셰이더 생성을 막고 디바이스 수명 동안 Metal 파이프라인 상태 객체(PSO)를 재사용합니다.
- 사전 캐시 웜업(Warmup) 구조로 쾌적한 전투 환경을 제공합니다.

#### 실험적 NGX 노출 보정 및 진단

`YAAGL_METALFX_EXPOSURE_SCALE_FIX=1`로 범위가 제한된 실험적 보정을 선택할 수 있습니다. 자동 노출과 호출자가 제공한 노출 텍스처가 모두 없는 수동 노출 HDR 평가에서, 유한한 양수 `DLSS.Exposure.Scale` 값이 `1`이 아니면 내부 1×1 `R16Float` 노출 텍스처로 표현합니다. 기존 노출 텍스처와 `DLSS.Pre.Exposure`는 변경하지 않으며, scale이 없거나 `0` 또는 `1`이면 건너뜁니다. 기본값은 꺼짐입니다. NVIDIA와 동등한 출력이나 jitter 수정을 주장하지 않습니다.

`YAAGL_METALFX_DIAGNOSTICS=1`을 설정하고 `YAAGL_METALFX_LOG`에 절대 경로를 지정하면 제한된 JSONL 진단 로그를 기록합니다. 로그 파일 모드는 `0600`이며 8,192개 이벤트 이후 기록을 중단합니다. 공개 API 진입부터 내부 평가, 기록된 명령, replay/encode 단계와 가능한 경우 encode 이후의 실제 MetalFX 속성까지 추적합니다. 상관관계 식별자는 진단용 record/command 식별자이며 엔진 프레임 ID나 GPU 완료 증명이 아닙니다. 평가와 GPU 출력이 성공하더라도 기존 legacy 구현의 `Unsupported feature` 경고는 남을 수 있습니다.

#### 실험적 MetalFX frame probe (이름표/NPC 지연 관찰)

MetalFX temporal scaling 단계에서 이름표가 NPC와 어긋나는 문제를 관찰하기 위한 선택적 진단입니다. NGX 평가, 완료된 MPL 기록, replay, 실제 native MetalFX encode 지점을 후킹하고 GPU 캡처용 `YAAGL.MFX`, `YAAGL.PASS`, `YAAGL.draw` debug group을 남깁니다. 기본값은 꺼짐이며 전역 jitter 부호, motion scale, depth 규약, UI 합성 순서를 바꾸지 않고 셰이더나 카메라 상태도 수정하지 않습니다. 기존 `YAAGL_METALFX_TEMPORAL` 보정은 probe 실행에서 함께 켜지 않습니다.

- `YAAGL_METALFX_FRAME_PROBE=1` — probe를 활성화합니다.
- `YAAGL_METALFX_PROBE_DIR=<절대 경로 비공개 0700 디렉터리>` — 출력 디렉터리입니다. 절대 경로여야 하고, 본인 소유에 모드 `0700`이어야 하며 symlink는 거부합니다.
- `YAAGL_METALFX_PROBE_RESET_HISTORY=1` — 두 번째 별도 A/B 실행에서만 사용합니다. 기본값은 꺼짐이며 수정책이 아닙니다.
- `MTL_CAPTURE_ENABLED=1` — Wine 시작 전에 필요하며, Command Line Tools만이 아니라 full Xcode GPU 도구가 필요합니다.

probe는 반드시 별도 복사본에 설치합니다. 설치된 런타임, 게임 파일, 사용자 prefix를 대상으로 삼지 않습니다:

```bash
python3 scripts/stage-runtime.py \
  --wine-source "$HOME/path/to/current/wine" \
  --wine-dest "$HOME/zzz-wine-frame-probe" \
  --pristine-d3dmetal <pristine GPTK 4.0b2 D3DMetal 바이너리> \
  --probe-dir "$HOME/zzz-metalfx-probe" \
  --check
```

`--pristine-d3dmetal`에는 순정 GPTK 4.0b2 D3DMetal 바이너리를 지정해야 합니다. SHA-256이 `d3dmetal-pso-cache/layout.json`의 `source.sha256`(`f8640e6b0974277068821d44bd398dcc0f42cbb730d07f3afad97843e72a6ea3`, Mach-O UUID `674e662b-6b5c-3fd9-9a8a-f415609d2f6a`)과 다르면 도구가 거부하므로, 이미 패치된 바이너리나 설치된 런타임의 D3DMetal을 넘겨서는 안 됩니다. `--check`가 성공한 뒤 **같은 명령에서 `--check`만 제거**해 실행합니다. 이 과정은 x86_64 dylib를 빌드하고, 런타임 전체를 새 디렉터리로 복사하고, 해당 순정 바이너리에 기존 25-hook 패치 layout을 적용하고, 결과물을 설치·서명한 뒤 `wine.real` 실행 직전에 probe 환경을 설정하는 helper를 넣습니다. 설치된 Wine, 게임 파일, 원격 저장소는 수정하지 않으며, 지원하지 않는 wrapper나 지문이 맞지 않는 바이너리는 거부합니다. 이후 평소와 **동일한 prefix·게임 경로·인자**를 유지하고 Wine 경로만 `<wine-dest>/bin/wine`으로 바꿔 ZZZ를 실행합니다.

게임에서 DLSS를 켜고 지연이 나타나는 NPC를 화면에 둔 뒤:

```bash
python3 scripts/probe-control.py "$PROBE_DIR" list
python3 scripts/probe-control.py "$PROBE_DIR" capture --presentations 8 --timeout 15
python3 scripts/probe-control.py "$PROBE_DIR" stop

python3 scripts/analyze-probe.py "$PROBE_DIR/probe-<pid>-SESSION.jsonl"
```

`ready-<pid>.json`은 MPL NGX 평가를 실제로 관측한 프로세스에만 생기며, 후보가 여러 개면 PID를 추측하지 말고 `--pid`로 지정합니다. 캡처는 device 전체를 대상으로 하고 실행 중 프레임이 느려질 수 있습니다. `capture requested`는 요청을 기록했다는 뜻일 뿐이므로 로그에 `capture_started`와 `capture_stopped`가 실제로 있는지 확인하고, `capture_unavailable`, `NO_NATIVE_ENCODE`, timeout 종료는 실패로 취급합니다. 8회는 device에서 관측한 presentation callback 수이지 확정된 `Present[N]` 개수가 아니므로 첫 1~2개와 마지막 불완전 구간은 버립니다. analyzer는 정확히 한 프로세스·한 실행의 로그에만 사용하고 `<log>.report.json`과 `<log>.report.encodes.csv`를 만듭니다. writer는 비동기이며 실행당 64MiB로 제한되므로, capacity 또는 overflow 경고가 있으면 그 로그는 불완전한 것으로 봅니다.

`.gputrace`를 Xcode로 열고 **`YAAGL.MFX` 그룹을 먼저** 찾습니다. 대응하는 JSON `encode_before`에서 실제 bound color/output/depth/motion 객체를 확인할 수 있습니다. 이어서 다음을 따라갑니다. **A**는 실제 MetalFX가 읽는 color, **B**는 실제 MetalFX 출력, **C**는 presentation에 사용한 drawable texture입니다. `YAAGL.PASS`는 attachment와 command buffer 연결 표식, `YAAGL.draw`는 후보 이름표 draw 표식입니다. 텍셀 자체는 JSON에 없으므로 native trace에서 해당 이벤트의 리소스 상태를 직접 비교합니다.

한계는 다음과 같습니다.

- `eval_id`, `record_id`, `encode_id`, `object oid`, `acquisition_id`는 진단용 식별자이며 엔진 프레임 ID도 GPU 완료 증명도 아닙니다. `record_bytes_match`는 CPU command bytes가 같다는 뜻일 뿐입니다.
- JSON은 **CPU 쪽 command bytes와 바인딩만** 증명합니다. MetalFX 입력 텍셀, buffer가 카메라 행렬로서 갖는 의미, 어느 장면 프레임이 늦는지는 판정하지 못합니다. 주소가 반복되어도 동일한 영상 내용이라는 뜻이 아닙니다.
- 캡처는 타이밍을 바꾸므로 FPS 벤치마크나 성능 기준선으로 사용하지 않습니다.
- probe는 이름표 지연을 수정하지도, 검증하지도 않으며 수정책으로 제시해서는 안 됩니다. 캡처를 요청했다는 사실은 캡처 성공을 의미하지 않습니다.

### 5. 커서 소유권과 RawInput 분리 (`0004-macdrv-reset-rawinput-baseline.patch`)
- 네이티브 커서 표시와 창 판정은 유지하고, 커서 소유권 동기화가 포인터 좌표를 변경하지 않도록 분리했습니다.
- warp 변위를 보정한 마우스 이동량을 포인터 좌표와 별도로 전달합니다. 첫 실제 이동을 버리지 않고 소수 이동량과 이벤트 병합을 보존합니다.
- v1.0.5 동봉 런타임은 Wine 클라이언트·서버 모듈을 함께 빌드한 프로토콜 **966**입니다. `winemac`만 교체하거나 이전 프로토콜 965 서버와 섞어 사용하면 안 됩니다.
- `node scripts/wine-mac-cursor-input-regression.mjs`로 실제 소스에서 추출한 입력 로직을 검사합니다. 네이티브 커서 픽셀과 게임 카메라의 실제 동작 검증을 대신하지는 않습니다.

### 6. 영상/오디오 및 시스템 자원 최적화 (`0005`, `0006`, `0008` ~ `0014`)
- **미디어 재생 개선**: GStreamer 및 Media Foundation 최적화로 인게임 컷씬 및 비디오 재생이 끊기지 않습니다.
- **오디오 레이턴시 감소**: CoreAudio 버퍼링을 개선하여 소리 밀림 현상을 줄였습니다.
- **창 메시지 및 네트워크**: 윈도우 이벤트 큐와 소켓 통신을 다듬어 입력 반응 속도를 높였습니다.

---

## 📂 저장소 구조

```
zzz-wine-d3dmetal-dx12/
├── external/               # Apple GPTK 4.0b2 순정 D3DMetal.framework 원본
│   └── D3DMetal.framework  # D3DMetal 바이너리 및 libmetalirconverter.dylib
├── dlls/                   # Wine 11.17 수정/패치된 DLL 소스 코드
├── server/                 # ARM64 네이티브 지원 및 msync가 적용된 wineserver 소스
├── include/                # msync.h 등 추가/수정된 헤더 파일
├── d3dmetal-pso-cache/     # libYaaglNativePsoCache 네이티브 캐시 소스 (Objective-C++)
├── patches/                # 적용된 개별 패치 파일 모음 (0001 ~ 0014)
│   ├── wine-tuned/         # 성능 최적화 및 버그 수정 패치 14종
│   └── wine-p3/            # 베이스라인 호스트 msync 및 D3DMetal 브릿지 패치
├── scripts/                # Wine 빌드 및 패키징 스크립트
└── installer/              # SwiftUI 기반 간편 GUI 설치 프로그램 소스 및 빌드 산출물
    ├── ZZZ Wine DX12 Installer.app  # 컴파일된 실행형 macOS 앱 번들
    ├── zzz-wine-installer           # CLI 실행 바이너리
    ├── RuntimePackage.swift         # 사전 빌드 Wine 패키지 메타데이터
    ├── AsarPatcher.swift            # Yaagl Wine 메뉴 등록 패처
    ├── InstallerEngine.swift        # 자동 감지, 설치, 등록 및 복원 엔진
    ├── ContentView.swift            # SwiftUI 사용자 인터페이스
    └── resources/typescript.js      # 메뉴 패칭용 내장 JavaScript 컴파일러
```

---

## 🛠️ 소스 코드 직접 빌드하기

### 요구 환경
- macOS 26.0 이상 (Apple Silicon M1/M2/M3/M4/M5), Rosetta 2, macOS 26 SDK
- Xcode Command Line Tools (`xcode-select --install`)
- LLVM MinGW 크로스 컴파일러 (`/opt/llvm-mingw-...`)
- Bison, Pkg-config, GStreamer 의존성
- 준비된 P3 소스·호스트·의존성 트리·provenance, 로컬 GPTK 오버레이 및 Steam helper 파일. 이 저장소는 외부 빌드 입력을 다운로드하지 않습니다.

### 빌드 명령어
```bash
# 검증된 로컬 입력 디렉터리와 설치된 SDK 경로를 지정합니다.
export WINE_P3_ROOT="/absolute/path/to/prepared/wine-p3"
export YAAGL_STEAM_HELPER_DIR="/absolute/path/to/protonextras"
export GPTK_SOURCE="/absolute/path/to/gptk-overlay/wine"
export MACOSX_DEPLOYMENT_TARGET=26.0
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
export WINE_PACKAGE_NAME=wine-11.17-zzz-dx12-gptk4b2-macos26
export WINE_RUNTIME_ID=11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server

# 1. 새 build/wine-tuned 디렉터리에서 Wine 오버레이를 빌드합니다.
./scripts/build-wine-tuned.sh all

# 2. 네이티브 PSO 모듈을 빌드하고 런타임 의존성을 패키징합니다.
./scripts/package-wine-p3-runtime.sh build/wine-tuned/host "$GPTK_SOURCE" \
  build/wine-tuned/provenance.json build/wine-tuned/package

# 3. GUI 설치 관리자 컴파일
./installer/build.sh
```

### NGX smoke fixture 빌드 및 실행

fixture에는 공식 NVIDIA NGX SDK의 외부 헤더(`nvsdk_ngx.h`가 있는 include 디렉터리)와 LLVM-MinGW가 필요합니다. SDK 헤더는 저장소에 포함하지 않습니다. NGX parameter 인터페이스가 Microsoft C++ ABI를 사용하므로 작은 wrapper object는 MSVC 타깃으로 빌드해야 하며, 나머지 fixture는 Windows 라이브러리 연결을 위해 MinGW 타깃을 사용합니다.

```bash
C=/path/to/llvm-mingw/bin/clang++
NGX_SDK_INCLUDE=/path/to/NVIDIA-NGX-SDK/include

"$C" --target=x86_64-pc-windows-msvc -std=c++20 -fno-exceptions -fno-rtti \
  -Wall -Wextra -Werror -I"$NGX_SDK_INCLUDE" \
  -c d3dmetal-pso-cache/ngx-smoke-msvc.cpp -o build/ngx-smoke-msvc.obj
"$C" --target=x86_64-w64-mingw32 -std=c++20 -Wall -Wextra -Werror \
  -static -Wl,--stack,8388608 -I"$NGX_SDK_INCLUDE" \
  d3dmetal-pso-cache/ngx-smoke.cpp build/ngx-smoke-msvc.obj \
  -ld3d12 -ldxgi -luuid -o build/ngx-smoke.exe
```

이 실행 파일은 복사한 테스트 런타임과 폐기 가능한 격리 Wine prefix에서만 실행하고 게임 또는 사용자 prefix에는 실행하지 마세요. 종료 상태 0과 `NGX_SMOKE_PASS`가 성공 조건입니다. 패키지 Wine wrapper는 `D3DM_MTL4=1`을 강제합니다. legacy 경로를 의도적으로 검사할 때는 wrapper에 `D3DM_MTL4=0`을 설정하지 말고, 격리 런타임의 `wine.real`과 필요한 legacy 환경을 사용해 wrapper를 우회하세요.

설치 앱 빌드에는 새 `build/wine-tuned/package/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz` 아카이브 또는 명시적인 `RUNTIME_ARCHIVE_SOURCE`가 필요합니다. 기존에 설치된 오래된 런타임을 대신 포함하지 않습니다.

### frame probe 호스트 테스트 빌드 및 실행

```bash
bash scripts/test-frame-probe-native.sh
python3 scripts/test-frame-probe-tools.py
```

`scripts/test-frame-probe-native.sh`는 ASan/UBSan 기반의 portable C++ ledger 테스트를 빌드·실행하고, macOS에서는 probe 런타임 훅의 CPU 전용 Objective-C mock도 함께 실행합니다. 이 mock은 probe의 상태 전이만 검사하며 GPU 캡처와 ZZZ 실행은 다루지 않습니다. `scripts/test-frame-probe-tools.py`는 analyzer, 캡처 제어 CLI, staging 가드 검사를 수행합니다. 모듈 빌드는 기존과 동일한 `node scripts/build-d3dmetal-pso-cache.mjs <out-dir>`이며, 이제 `d3dmetal-pso-cache/frame-probe.mm`도 함께 컴파일하고 QuartzCore를 링크합니다.

### DX12 실행 회귀 테스트

```bash
node --test scripts/test-dx12-launch-regression.mjs
```

저장소에 포함된 Yaagl 0.3.18 소스 발췌 fixture를 사용하므로 Wine 빌드 산출물, 별도 다운로드, Git 이력이 필요하지 않습니다. 변환된 실제 카탈로그에서 선택한 항목으로 실행 객체를 만들고, 일반·Steam 실행, 기존 Wine 항목 보존, 구버전 ID 조건 및 D3DMetal 전체 대상 조건의 업그레이드를 검사합니다. 실제 게임이나 GPU를 실행하는 테스트는 아닙니다.

---

## 📄 라이선스 (License)

- Wine 소스 코드는 **GNU Lesser General Public License (LGPL v2.1+)**를 따릅니다.
- D3DMetal 관련 인터페이스 및 설치 프로그램 코드는 본 저장소의 라이선스를 따릅니다.
