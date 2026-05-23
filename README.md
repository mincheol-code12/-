# eCommerce 퍼널 이탈 분석 & 재구매 예측 모델

## 프로젝트 개요

eCommerce 플랫폼(Kaggle) 데이터를 활용해 퍼널 구간별 이탈 원인을 통계적으로 검증하고, ML 기반 CRM 타겟 최적화로 이어지는 분석 프로젝트입니다.

- **분석 대상**: 3,980,480명 / 2개월 (2019년 10~11월)
- **데이터 출처**: [eCommerce behavior data from multi category store (Kaggle)](https://www.kaggle.com/datasets/mkechinov/ecommerce-behavior-data-from-multi-category-store)

---

## 파일 구성

| 파일 | 설명 |
|---|---|
| `[ecommerce 분석 Part 1].ipynb` | DA 파트 — View→Cart / Cart→Purchase / Purchase→Repurchase 구간별 이탈 원인 가설 검증 |
| `[ecommerce 분석 Part 2].ipynb` | DS 파트 — RF 기반 재구매 예측 모델 + Combined Score CRM 타겟 최적화 |
| `데이터마트_쿼리_정리.sql` | 퍼널 집계 및 분석용 데이터마트 쿼리 |

---

## 분석 흐름

```
DA: 퍼널 이탈 분석
├── View → Cart     : apparel 카테고리 전환율 6.0% (전체 평균 13.3%)
├── Cart → Purchase : 세션 이탈 유저 18.3%가 나중에 동일 상품 구매 (지연 전환)
└── Purchase → Repurchase : cart 재추가 행동이 재구매의 가장 강력한 선행 지표 (V=0.505)
        ↓
DS: 규칙기반 CRM의 한계 → ML 타겟 최적화
└── Combined Score(재구매 확률 × 구매 가치) 기반 Top 50% 타겟팅
    → 발송 수 22.5% 감소, Value Recall 83.7% 유지
```

---

## 사용 기술

- **언어**: Python, SQL
- **라이브러리**: pandas, numpy, scipy, scikit-learn, matplotlib
- **통계 검정**: Cramér's V, rank-biserial r (효과크기 병행 기준)
- **모델**: Logistic Regression, Random Forest, XGBoost
