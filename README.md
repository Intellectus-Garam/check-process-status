# check-process-status

int2DDS long-term 테스트(tmux 세션들)를 매일 점검해서 Slack으로 요약을 보냅니다.
생존 / 수신 / 메모리 3가지를 확인합니다.

## 설정 (기기당 한 번)

```sh
cp manifest.example.conf manifest.conf   # 그 기기에 안 떠 있는 줄은 삭제
cp .env.example .env                      # SLACK_WEBHOOK_URL 채우기
```

## 실행

```sh
# 미리보기: 짧게 대기 + Slack 안 보내고 화면에 출력 (.env의 webhook 비워둔 상태)
WAIT_SECONDS=5 ./watch.sh

# 실제 실행: Slack 전송 (.env에 webhook 채워야 함)
./watch.sh
```

## 매일 자동 (cron)

```sh
crontab -e
```
```cron
0 8 * * * /home/ubuntu/check-process-status/watch.sh >> /home/ubuntu/check-process-status/watch.log 2>&1
```

## 설정값 (환경변수)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `WAIT_SECONDS` | `60` | sub 수신 확인용 두 캡처 사이 대기(초) |
| `MEM_THRESHOLD_MB` | `1500` | 프로세스 RSS 경고 임계값(MB) |
| `SLACK_WEBHOOK_URL` | (빈값) | Slack webhook. 비우면 화면 출력만 |
