"""Coach orchestration kernel (spec 4): MetricsState, Director, EventEngine, CueQueue.

Nothing here branches on the activity type; every activity difference lives in a profile
(`coachw.profiles`). Everything is plain code driven by an injected clock, so it can be tested
with synthetic frames and no model.
"""
