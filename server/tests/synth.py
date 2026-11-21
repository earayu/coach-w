"""Synthetic workouts for coach tests. All data here is made up."""

from __future__ import annotations

from collections.abc import Callable

from coachw.protocol import PROTOCOL_VERSION, MetricsFrame, WorkoutState

T0_MS = 1763726400000


class Clock:
    def __init__(self, now: float = 1000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def frame(
    seq: int,
    elapsed: float,
    *,
    activity: str = "running",
    state: WorkoutState = WorkoutState.RUNNING,
    **metrics: float | None,
) -> MetricsFrame:
    return MetricsFrame(
        v=PROTOCOL_VERSION,
        seq=seq,
        ts=T0_MS + int(elapsed * 1000) + seq,
        activity=activity,
        state=state,
        elapsed_s=elapsed,
        **{k: v for k, v in metrics.items() if v is not None},
    )


class Runner:
    """Feeds one frame per simulated second into `sink`, advancing `clock` with it."""

    def __init__(
        self,
        sink: Callable[[MetricsFrame], object],
        clock: Clock,
        *,
        activity: str = "running",
        on_tick: Callable[[], object] | None = None,
    ) -> None:
        self.sink = sink
        self.clock = clock
        self.activity = activity
        self.on_tick = on_tick
        self.seq = 0
        self.elapsed = 0.0
        self.distance = 0.0
        self.energy = 0.0

    def send(self, state: WorkoutState = WorkoutState.RUNNING, **metrics: float | None) -> None:
        self.seq += 1
        self.sink(
            frame(
                self.seq,
                self.elapsed,
                activity=self.activity,
                state=state,
                distance_m=self.distance,
                **metrics,
            )
        )

    def run(
        self,
        seconds: float,
        *,
        speed: float | None = 3.0,
        hr: float | None = 150,
        cadence: float | None = 170,
        gct: float | None = None,
        power: float | None = None,
        kcal_per_s: float | None = None,
        state: WorkoutState = WorkoutState.RUNNING,
    ) -> None:
        for _ in range(int(seconds)):
            self.clock.advance(1)
            if state is WorkoutState.RUNNING:
                self.elapsed += 1
                self.distance += speed or 0
                self.energy += kcal_per_s or 0
            self.send(
                state,
                speed_mps=speed,
                hr_bpm=hr,
                cadence_spm=cadence,
                gct_ms=gct,
                power_w=power,
                energy_kcal=self.energy if kcal_per_s is not None else None,
            )
            if self.on_tick:
                self.on_tick()
