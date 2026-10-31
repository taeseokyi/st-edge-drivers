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
- `hubpackage/src/init.lua`: 대시보드 표시 방식(none/문자열/숫자)별 프로필 분리, 숫자 추출 시
  `keynumvalue` 와 temperatureMeasurement 로 이벤트 발행, 주기적 자동 refresh 타이머 추가.
- `hubpackage/config.yml`: 드라이버 이름/packageKey 변경.
- `hubpackage/capabilities/partyvoice23922.keyvalue.presentation.{yaml,json}`: 표시 설정 변경.
- `hubpackage/capabilities/cleverflower44023.*`: 추가 (본인 네임스페이스 capability).
- `hubpackage/profiles/webrequestm*_dash{none,str,num}.v2{e,f}.yaml`: 추가. 원본 profiles 는 제거.
- `hubpackage/*_device-config.v2f.json`: 추가.

`edgeWeather/`
- `hubpackage/config.yml`: 드라이버 이름/packageKey 변경.
- `hubpackage/profiles/weather_v1g.yaml`, `weather_v1i.yaml`: refresh 주기 최소값 5 → 1 분.

## 커스텀 capability

- `partyvoice23922.*` : Todd 의 네임스페이스. 사용만 가능, 정의 변경 불가.
- `cleverflower44023.*` : 본인 네임스페이스. 새 capability 는 여기에 만든다.

## 배포

```
smartthings edge:drivers:package <폴더>/hubpackage
smartthings edge:channels:assign <driverId> --channel <channelId>
smartthings edge:drivers:install <driverId> --hub <hubId>
```

## 허브 로그

```
smartthings edge:drivers:logcat <driverId> --hub-address <hub-ip>
```

허브 IP 를 모르면 LAN 대역에서 TCP 9495 가 열린 호스트를 찾는다. 채널/허브 ID 와 IP 같은
개인 식별자는 `docs/local/` (git 제외) 에 둔다.

## 변경 이력

- 2026-10-31: bert-ner-tf 저장소의 SmartThings/ 폴더에서 분리.
