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

## 후속: 드라이버 전환 뒤 5분 주기 갱신 중단 (2026-11-01)

### 증상

전환 뒤 Counter Utility / 야간차단의 duration 이 5분마다 올라오지 않고, 앱을 열거나 refresh
명령을 보낼 때만 갱신됐다. 10분/15분 reset 자동화도 그때만 뒤늦게 동작했다
(예: 92분, 110분 값이 한 번에 찍히고 reset).

### 원인

두 기기 모두 Contact sensor Behavior 설정이 `disable` 이다. `handle_switch` 는 `on_open` /
`on_closed` 일 때만 `contactset` 테이블을 만들고, `disable` 이면 nil 인 채 인덱싱해서 Lua
에러로 핸들러가 중단된다. switch 이벤트는 그 앞에서 이미 emit 되어 앱에는 켜진 것으로 보이지만,
그 뒤의 baseTime 설정과 `start_auto_refresh`(타이머 시작)가 실행되지 않는다. 허브의 Todd V1.1
(비공개 개정판)은 `disable` 옵션과 `increment` 설정이 있어 정상이었고, 공개 소스(V1)에는 없다.

근거: 전환 전 히스토리는 xx:x5:26 에 정확히 5분 간격, 전환 후에는 스케줄 이벤트 없음.
11-01 09:47~09:54 logcat 7분 캡처에 타이머 발화(`Calc:` 로그) 없음.

### 수정 (드라이버 버전 0.5 → 0.8, 최종 패키지 2026-11-01T11:59:31)

1. `contactset` 이 있을 때만 contact 이벤트 emit (`disable` 처리).
2. `increment` 설정 추가: 프로필(V1c 두 개)에 integer 설정, add/subtract/링크 카운트가
   `device.preferences.increment`(기본 1) 만큼 증감.
3. duration reset 시 switch 가 켜져 있으면 `start_auto_refresh` 를 다시 호출해 타이머를 새
   baseTime 에 정렬. reset 이 타이머 틱보다 1초 늦게 들어오면 이후 틱이 4, 9, 14, 19 로 찍혀
   15 를 건너뛰는 문제가 있었다(11-01 10:00 야간차단에서 관찰).

설치 뒤 드라이버가 재시작되며 `device_init` 이 switch on 상태를 보고 타이머를 시작하므로
기기를 다시 켤 필요는 없다. 10:05:40 에 두 기기 모두 명령 없이 타이머 갱신 확인.

### 전체 검토 후 추가 개선 (버전 0.6, 2026-11-01)

- 재시작 정렬: `start_auto_refresh` 가 첫 틱을 baseTime 기준 다음 frequency 경계에 맞춘다
  (`call_with_delay` 뒤 `call_on_schedule`). 허브 재부팅·드라이버 업데이트 뒤에도 5/10/15 유지.
  설치 직후 로그: "Aligning refresh timer: first tick in 260 s, then every 300 s".
- `resetnum`(지정 숫자로 리셋) 핸들러 추가. V1c 프로필 두 개의 counter 컴포넌트에 capability 추가.
  프레젠테이션(duration.json / counter.json)에는 이미 들어 있었고, counter.json 의 자동화 액션
  component 가 `main` 으로 잘못돼 있어 `counter` 로 고치고 새 vid 를 만들었다(docs/local 참고).
- `handler_infochanged`: frequency / scale / dashboard 를 각각 독립 `if` 로 처리. scale 변경 시 즉시
  duration 재표시.
- 방어 코드: scale 값이 비정상이면 hours 로, frequency 가 없으면 1800 으로, 10 미만이면 10 으로.
  baseTime 이 있는데 pauseTime 이 없는 상태에서 on 이 오면 새로 시작. 시계 역행 시 duration 0.
- 전역 변수 제거(`thisDriver`, `refreshtimer` 모두 local), 미사용 `cosock` require 와 주석 코드 삭제,
  switch off 시 타이머 정지를 pause/reset 공통으로 이동, `device_added` 에서 타이머 정지.
- `lastcmd` 갱신은 핸들러 끝에 그대로 둔다. 중간에 에러가 나면 같은 명령을 다시 보내 복구할 수 있다.
- 프레젠테이션 조회는 `presentation:device-config <vid> Taeseokyi` 처럼 mnmn 을 두 번째 인자로 줘야
  한다(기본값 SmartThingsCommunity 로는 404).
- 0.7: `switchoff` 를 pause→reset 으로 바꾸면(스위치 off 상태) 멈춰 있던 duration 을 즉시 0 으로, `behavior` 를
  on_open/on_closed 로 바꾸면 현재 switch 상태에 맞춰 contact 를 즉시 갱신.
- 검증(0.6): 10:38:37, 10:43:37 두 기기 모두 경계 정렬 틱, Counter Utility 10:43:38 10분 reset 자동화 정상.
  0.7 설치 후 재정렬 "first tick in 70 s / 68 s".
- 대시보드 표시(duration↔count) 변경은 서버에서는 즉시 반영된다(10:35:50 야간차단 프로필 edgeutil_count.v1c,
  presentation vid 428cfe5f 확인). 앱 화면이 안 바뀌면 앱 프레젠테이션 캐시이므로 앱을 완전히 종료 후 다시 연다.
- 대시보드에 "켜짐"만 보이고 count 가 안 보이던 문제: 프레젠테이션 dashboard.states 가 [switch, count] 순서인데
  현재 앱은 타일에 첫 상태 하나와 첫 동작 하나만 그린다. 두 JSON 모두 값(count / duration2)을 첫 상태로 옮겨
  새 vid 를 만들고(패키지 2026-11-01T11:47:55) 프로필에 반영했다. 패키징 시 프로필 ID 가 새로 발급되고 해당
  프로필을 쓰는 기기(야간차단)는 자동으로 새 presentation 으로 옮겨졌다. Todd 프로필에 남아 있는 기기
  (Counter Utility)는 앱에서 Dashboard 설정을 count 로 바꿨다 duration 으로 되돌리면 본인 프로필로 넘어온다.
- 0.8 프로필 의존성 제거: `device_init` 에서 한 번(영속 필드 `profileSynced`) dashboard 설정에 맞는 본인
  프로필로 `try_update_metadata` 를 호출한다. 다른 드라이버에서 넘어온 기기가 그 드라이버의 프로필·
  프레젠테이션에 남는 일이 없어진다. 설치 직후 Counter Utility 가 Todd 프로필(6c8ed2b6)에서
  edgeutil.v1c 로 옮겨졌고(presentation 3589acd6), 야간차단은 edgeutil_count.v1c 유지.
- 루틴 영향 없음: 야간차단이 10:35:50 프로필 변경 뒤에도 15분 reset 루틴이 10:48~11:48 매 15분 실행됨.
  루틴은 기기 ID + capability 로 묶이고 두 프로필의 capability 가 같다. 자동화 백업 시도 결과는
  docs/local/backup-2026-11-01/README.md (앱 루틴은 Rules API 에 안 잡혀 화면 캡처만 가능).

