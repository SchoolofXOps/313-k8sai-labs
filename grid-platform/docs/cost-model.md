# Cost model

## Fleet cost at 5% and at 60% utilisation

The 5% figure comes from Cast AI's 2026 State of Kubernetes Optimization report. It is a cited vendor figure, not a figure this course produced, and 60% is a design target used for comparison. Prices are declared assumptions: replace with your own quote.

~~~text
FLEET AT TWO UTILISATION LEVELS:
low      utilisation=0.05 useful_accel_hours=28032 cost_usd=2242560 usd_per_useful_accel_hour=80.00 useful_tokens_per_usd=112500
high     utilisation=0.60 useful_accel_hours=336384 cost_usd=2242560 usd_per_useful_accel_hour=6.67 useful_tokens_per_usd=1350000

~~~

## The four levers

Each lever is applied alone against the low-utilisation baseline. Their effects overlap, so do not add them up. Every effect is a declared assumption: replace with your own measurement.

### Share

~~~text
share    utilisation=0.15 useful_accel_hours=84096 cost_usd=2242560 usd_per_useful_accel_hour=26.67 useful_tokens_per_usd=337500
~~~

### Queue

~~~text
queue    utilisation=0.25 useful_accel_hours=140160 cost_usd=2242560 usd_per_useful_accel_hour=16.00 useful_tokens_per_usd=562500
~~~

### Pack

~~~text
pack     accelerators=56 utilisation=0.06 useful_accel_hours=28032 cost_usd=1962240 usd_per_useful_accel_hour=70.00 saving_usd=280320
~~~

### Reclaim

~~~text
reclaim  idle_hours_returned=159782 utilisation=0.07 useful_accel_hours=28032 cost_usd=1603432 usd_per_useful_accel_hour=57.20 saving_usd=639128
~~~
