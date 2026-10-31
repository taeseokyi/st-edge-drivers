# Counter Utility / 야간차단 오프라인 분석 (2026-10-31)

## 결론

앱에서 오프라인으로 보이는 카운터 기기 4개(Counter Utility, 야간차단, Counter Utility 1,
야간 차단1)는 **실제로는 정상 동작 중**이다. 2026-10-20 10:30:07Z 에 허브가 잠깐 클라우드
연결을 잃어 허브에 붙은 모든 기기가 OFFLINE 처리됐고, 다른 기기는 복귀했지만 카운터
드라이버는 `device:online()` 을 호출하지 않아 헬스 상태만 OFFLINE 에 멈춰 있다.

## 근거

- Zigbee 기기: 약 30초 뒤(10:30:34Z) 허브 헬스 리포트로 자동 복귀.
- Web Requestor 기기(경도측정, 수조온도측정): 10:30:40~45Z 복귀. 이 드라이버는
  `device_init` 끝에서 `device:online()` 을 호출한다
  (`webrequestor/hubpackage/src/init.lua:591`).
- 카운터 드라이버 소스(`counter_utility/hubpackage/src/init.lua`)에는 `online`/`offline`
  호출이 없다. LAN 타입 Edge 기기는 드라이버가 직접 online() 을 보내지 않으면 플랫폼이
  복귀시키지 않는다.
- 이벤트 히스토리와 허브 logcat 으로 두 카운터 드라이버 모두 ERROR/WARN 없이 자동화 명령
  (switch on, reset, add)을 처리하고 duration/count 이벤트를 올리는 것을 확인했다.
- 2026-10-26 펌웨어 업데이트(hubv4 3.42.15) 재부팅은 헬스 상태를 바꾸지 않았다.

## 기기 ↔ 드라이버 매핑

| 기기 | 드라이버 | 채널 | 헬스 |
|---|---|---|---|
| Counter Utility | Edge Counter Utility V1.1 (Todd) | Todd | OFFLINE |
| 야간차단 | 위와 동일 | Todd | OFFLINE |
| Counter Utility 1 | Edge Counter Utility V1 `af200fb2` (본인) | Tsyi | OFFLINE |
| 야간 차단1 | 위와 동일 | Tsyi | OFFLINE |
| Web Req Multi Master | Web Requestor Multi v1.2 (Todd) | Todd | ONLINE |
| 경도측정 / 수조온도측정 | Web Requestor Multi-Auto v1.4 `3d6b5cf9` (본인) | Tsyi | ONLINE |

- 허브: hub v4, fw 000.062.00015.
- Counter Utility 1 / 야간 차단1 은 2026-10-12 생성, provisioningState `DRIVER_SWITCH`.
- 야간차단 / 야간 차단1 은 프로필 `edgeutil_dur.v3`, Counter Utility 1 은 `edgeutil.v1c`.
- 기기 ID, 허브 ID, 채널 ID 는 `docs/local/` (git 제외) 에 있다.

## 해결 방향 (소스 수정은 사용자 결정)

1. 본인 드라이버(`af200fb2`): `device_init` 끝과 `device_added` 에 `device:online()` 추가 후
   재패키징, Tsyi Channel 에 올리면 Counter Utility 1, 야간 차단1 복귀.
2. Todd 드라이버를 쓰는 Counter Utility, 야간차단: 앱 기기 메뉴 → 드라이버 → 본인 드라이버로
   전환. 프로필이 달라 UI 변화 확인 필요.
3. 수정 없는 임시책: 기기 삭제 후 재생성(새 기기는 기본 ONLINE). 다음 연결 끊김 때 재발.

## 허브 로그

허브는 작업 PC 와 다른 서브넷에 있지만 outbound 접근이 가능하다. 허브 IP 는 `docs/local/`
참고.

```
smartthings edge:drivers:logcat af200fb2-8d22-4c81-b3c3-bbafb7f02198 --hub-address <hub-ip>
```

CLI 기본 허브가 SmartThings Station 으로 저장돼 있으므로 `--hub-address` 를 반드시 붙인다.
IP 가 바뀌면 허브 LAN 대역에서 TCP 9495 가 열린 호스트를 찾는다.

## 기타

- 커스텀 capability: `partyvoice23922.*` 는 Todd 네임스페이스(사용만 가능),
  `cleverflower44023.*` 는 본인 네임스페이스(정의 변경 가능).
- SmartThings API 토큰은 `.env` 의 `SMARTTHINGS_API_TOKEN` (이 저장소에는 복사하지 않음,
  .gitignore 로 제외).
- 디바이스 preferences 는 REST 직접 호출 시 Accept 헤더 오류가 나므로
  `smartthings devices:preferences <deviceId>` 를 쓴다.
