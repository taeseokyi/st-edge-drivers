# Web Requestor: 프로필 의존성 제거, Todd 드라이버 정리 (2026-11-01)

## 배경

Counter Utility 와 같은 작업. Todd 의 Web Requestor Multi v1.2 드라이버에 "Web Req Multi Master"
기기 하나가 남아 있었다(설정은 모두 기본 자리표시자 URL, 이벤트 히스토리 0건, 미사용).
본인 드라이버(Web Requestor Multi-Auto)에는 수조온도측정(마스터형, dashnum.v2f)과
경도측정(추가형, addl_dashdkh.v2f)이 있다.

## 드라이버 수정 (v1.5, 패키지 2026-11-01T12:12:09)

- `device_init` 이 dashboard 설정과 무관하게 항상 number 프로필로 `try_update_metadata` 하고 있었다.
  드라이버가 재시작될 때마다 dKH/none/string 선택이 number 로 되돌아가는 버그. 이번 설치 전까지
  재시작이 없어 드러나지 않았다.
- `profile_for(device)`: dashboard 설정 × 마스터 여부로 프로필을 고르는 함수 하나로 통일하고
  init 과 infoChanged 양쪽에서 쓴다. init 에서 호출하므로 다른 드라이버에서 넘어온 기기도 첫 init 에
  본인 프로필로 옮겨진다(프로필 의존성 제거).
- `device_removed(_, device)` 가 본문에서 `driver` 를 써서 기기 삭제 시 타이머 취소가 에러 나던 것 수정.
- 안 쓰는 프로필 상수 6개 제거.

설치 후 로그: 수조온도측정 → webrequestm_dashnum.v2f, 경도측정 → webrequestm_addl_dashdkh.v2f
(설정대로 유지).

## 기기 전환과 Todd 드라이버 제거

```
smartthings edge:drivers:switch --hub <hubId> --driver 3d6b5cf9-5e1c-40f3-ba80-45e9c41abb97 --include-non-matching <masterDeviceId>
smartthings edge:drivers:uninstall a7d4ff68-2e8b-41f7-9be7-62bbe70f88f8 --hub <hubId>
```

Counter Utility 쪽 Todd 드라이버(e67c842f)는 같은 날 먼저 제거했다. 기기 ID 는 docs/local 참고.

## 결과

- Web Req Multi Master: 본인 드라이버로 전환 약 30초 뒤 ONLINE, 프로필은 dashboard 설정(none)에 따라
  webrequestm_dashnone.v2e 로 자동 이동. 전환 시 `device_added` 가 실행돼 상태가 초기화되지만 미사용 기기라 영향 없음.
- 경도측정 / 수조온도측정: 설치 후 재시작에서도 각각 addl_dashdkh.v2f / dashnum.v2f 유지.
- Todd 의 Web Requestor Multi v1.2(a7d4ff68)는 사용하는 기기 0개 확인 후 허브에서 제거.
- refreshrate 설정 단위는 **분**이다(경도측정 60분, 수조온도측정 5분). 로그에서 폴링을 보려면 그 이상 캡처해야 한다.
