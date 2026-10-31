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

| 기기 | 드라이버 | 채널 | 헬스 (조사 시점 → 처리 후) |
|---|---|---|---|
| Counter Utility | Edge Counter Utility V1.1 (Todd) → 본인 V1 `af200fb2` (10-31 전환) | Todd → Tsyi | OFFLINE → ONLINE |
| 야간차단 | 위와 동일 | Todd → Tsyi | OFFLINE → ONLINE |
| Counter Utility 1 | Edge Counter Utility V1 `af200fb2` (본인) | Tsyi | OFFLINE → ONLINE → 10-31 삭제 |
| 야간 차단1 | 위와 동일 | Tsyi | OFFLINE → ONLINE → 10-31 삭제 |
| Web Req Multi Master | Web Requestor Multi v1.2 (Todd) | Todd | ONLINE |
| 경도측정 / 수조온도측정 | Web Requestor Multi-Auto v1.4 `3d6b5cf9` (본인) | Tsyi | ONLINE |

- 허브: hub v4, fw 000.062.00015.
- Counter Utility 1 / 야간 차단1 은 2026-10-12 생성, provisioningState `DRIVER_SWITCH`.
- 야간차단 / 야간 차단1 은 프로필 `edgeutil_dur.v3`, Counter Utility 1 은 `edgeutil.v1c`.
- 기기 ID, 허브 ID, 채널 ID 는 `docs/local/` (git 제외) 에 있다.

## 해결 결과 (2026-10-31 처리 완료)

원본 카운터 기기 2개가 본인 드라이버(`af200fb2`)로 ONLINE 복귀했고, 복제본 2개는 삭제했다.

1. **드라이버 수정**: `counter_utility/hubpackage/src/init.lua` 의 `device_init` 끝과
   `device_added` 끝에 `device:online()` 추가 (webrequestor 와 같은 패턴). 패키징
   (버전 2026-10-31T10:28:41) → Tsyi Channel 배정 → 허브 설치. 설치 약 1분 뒤
   Counter Utility 1, 야간 차단1 이 ONLINE (10:29:33Z).
2. **Todd 드라이버 기기 전환**: 앱의 드라이버 메뉴에는 본인 드라이버가 뜨지 않았다. LAN 기기는
   fingerprint 가 없어 플랫폼이 "매칭 안 됨"으로 분류하기 때문이다. CLI 로 강제 전환했다.

   ```
   smartthings edge:drivers:switch --hub <hubId> --driver af200fb2-8d22-4c81-b3c3-bbafb7f02198 --include-non-matching <deviceId>
   ```

   Counter Utility, 야간차단 모두 전환 약 20초 뒤 ONLINE (10:44:38Z).

   **주의: 드라이버 전환 시 `device_added` 가 다시 실행돼 상태가 초기화된다.** 전환 시각에
   switch off, count 0, duration 0 이벤트가 한꺼번에 나왔다. 야간차단은 전환 직전
   switch on / count 9 / duration 15 였고, Counter Utility 는 switch on / count 1 /
   duration 10 이었다. 켜져 있어야 할 기기는 전환 뒤 다시 켜야 한다.
3. **복제본 삭제**: Counter Utility 1, 야간 차단1 은 원본이 OFFLINE 으로 보여 10-12 에
   같은 설정으로 만들어 둔 복제본이었다. 원본이 복귀했으므로 10-31 에 삭제했다. 삭제 전
   확인: 생성 이후 이벤트 히스토리 없음, Rules API 참조 0건.
4. 프로필은 Todd 것(`edgeutil_dur.v3`)으로 남는다. `handler_driverchanged` 가 프로필을 바꾸지
   않기 때문인데, 이 프로필의 main 컴포넌트 capability 는 본인 드라이버가 emit 하는 것과
   같아(이미 본인 드라이버를 쓰던 야간 차단1 도 같은 프로필) UI 와 자동화는 그대로 동작한다.

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
