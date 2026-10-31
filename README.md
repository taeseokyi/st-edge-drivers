# st-edge-drivers

SmartThings Edge 드라이버 모음. Todd Austin(@toddaustin07)의 Apache 2.0 드라이버를 기반으로
Taeseok Yi 가 수정해 **Tsyi Channel** 로 배포한다.

| 폴더 | 원작 | 본인 배포 (packageKey / driverId) |
|---|---|---|
| `counter_utility/` | [counter_utility](https://github.com/toddaustin07/counter_utility) | `edgeUtil_V1` / `af200fb2-8d22-4c81-b3c3-bbafb7f02198` |
| `webrequestor/` | [webrequestor](https://github.com/toddaustin07/webrequestor) | `webreqmautov1.4` / `3d6b5cf9-5e1c-40f3-ba80-45e9c41abb97` |
| `edgeWeather/` | [edgeWeather](https://github.com/toddaustin07/edgeWeather) | `tsyi_edgeWeather_V1` |

## 라이선스

원본과 동일하게 Apache License 2.0 (`LICENSE`). 각 폴더의 원본 `LICENSE` 와 소스 머리의
저작권 고지는 그대로 둔다. 수정한 파일은 Apache 2.0 4(b) 에 따라 변경 사실을 표시한다.

### 원본 대비 변경 파일

`counter_utility/`
- `hubpackage/src/init.lua`: 프로필 이름을 `edgeutil.v1c`, `edgeutil_count.v1c` 로 변경.
- `hubpackage/profiles/edgeutil_profile_V1c.yaml`, `edgeutil_profile_count_V1c.yaml`: 추가.
- `hubpackage/counter.json`, `duration.json`: 추가 (device presentation).

`webrequestor/`
- `hubpackage/src/init.lua`: 대시보드 표시 방식(none/문자열/숫자/경도)별 프로필 분리, 숫자 추출 시
  `keynumvalue` 와 temperatureMeasurement 로 이벤트 발행, 경도(dKH) 모드는 `cleverflower44023.dkhvalue`
  로 숫자(자동화용)와 소숫점 3자리 문자열(표시용) 발행, 주기적 자동 refresh 타이머 추가.
- `hubpackage/config.yml`: 드라이버 이름/packageKey 변경.
- `hubpackage/capabilities/partyvoice23922.keyvalue.presentation.{yaml,json}`: 표시 설정 변경.
- `hubpackage/capabilities/cleverflower44023.*`: 추가 (본인 네임스페이스 capability).
- `hubpackage/profiles/webrequestm*_dash{none,str,num,dkh}.v2{e,f}.yaml`: 추가. 원본 profiles 는 제거.
- `hubpackage/*_device-config.v2f.json`: 추가.

`edgeWeather/`
- `hubpackage/config.yml`: 드라이버 이름/packageKey 변경.
- `hubpackage/profiles/weather_v1g.yaml`, `weather_v1i.yaml`: refresh 주기 최소값 5 → 1 분.

## 커스텀 capability

- `partyvoice23922.*` : Todd 의 네임스페이스. 사용만 가능, 정의 변경 불가.
- `cleverflower44023.*` : 본인 네임스페이스. 새 capability 는 여기에 만든다.
- `cleverflower44023.dkhvalue` : 경도(dKH) 표시용. 표준 temperatureMeasurement 는 플랫폼이 값을
  소숫점 1자리로 반올림해 저장하므로(7.29 → 7.3), 3자리를 보이려면 커스텀 capability 가 필요하다.
  `dkh`(number, 자동화 조건용) + `dkhtext`(string, `%.3f dKH` 로 포맷한 표시용) 두 속성.
  커스텀 capability 는 앱 기록 그래프가 없다. 그래프용으로 경도 프로필에 carbonDioxideMeasurement 를
  같이 두고 값을 1000배(7.29 dKH → 7290 ppm)로 발행한다. 시험 결과(2026-10-31): 온도는 플랫폼이
  1자리로 반올림(7.29 → 7.3), CO2 는 저장은 7.29 그대로지만 앱이 정수만 표시, powerMeter 는 그래프 부적합.

capability / presentation 등록과 device presentation(vid) 생성:

```
smartthings capabilities:create -i <cap>.json
smartthings capabilities:presentation:create <capId> 1 -i <cap>.presentation.json
smartthings presentation:device-config:create -i <profile>_device-config.v2f.json   # 결과의 vid 를 profile metadata 에
```

## 배포

```
smartthings edge:drivers:package <폴더>/hubpackage
smartthings edge:channels:assign <driverId> --channel <channelId>
smartthings edge:drivers:install <driverId> --hub <hubId>
```

패키징할 때마다 `channels:assign` 을 다시 해야 한다. 채널 배정은 드라이버 버전 단위라, 생략하면
`drivers:install` 이 성공했다고 해도 허브에는 이전 버전이 남는다 (`edge:drivers:installed --hub` 로 확인).
드라이버 안의 프로필 내용이 바뀌어도 기존 기기에는 자동 반영되지 않는다. webrequestor 는 앱에서
Dashboard State 를 다른 값으로 저장했다가 되돌리면 `try_update_metadata` 가 새 프로필을 붙인다.

LAN 기기는 fingerprint 가 없어 앱의 드라이버 메뉴에 다른 드라이버가 뜨지 않는다. 기기의
드라이버를 바꾸려면 CLI 로 강제한다.

```
smartthings edge:drivers:switch --hub <hubId> --driver <driverId> --include-non-matching <deviceId>
```

전환하면 새 드라이버의 `device_added` 가 실행돼 switch/count/duration 이 초기화된다.

## 허브 로그

```
smartthings edge:drivers:logcat <driverId> --hub-address <hub-ip>
```

허브 IP 를 모르면 LAN 대역에서 TCP 9495 가 열린 호스트를 찾는다. 채널/허브 ID 와 IP 같은
개인 식별자는 `docs/local/` (git 제외) 에 둔다.

## 변경 이력

- 2026-10-31: bert-ner-tf 저장소의 SmartThings/ 폴더에서 분리.
- 2026-10-31: webrequestor 에 경도(dKH) 대시보드 모드 추가 (`extractdkh`, 소숫점 3자리).
