# Stream-copy assessment

EditorCore now includes `StreamCopyAssessment`, a pure assessment of picture and
audio independently. It is a foundation for the planned **Copy original streams**
workflow. The app still exports rendered ProRes/PCM; no stream-copy export command
or packet verifier is implemented.

The initial assessment accepts at most one component of each kind, covering the
whole sequence without generated gaps or duration changes. It checks original
stream identity, source offsets, raster, square pixels, rotation, exact frame rate,
audio layout/sample rate, whole-stream channel selection, routing, gain and fades.
It rejects stills, multiple components and unsupported transformations with typed
reasons. Edited audio can be rejected independently while picture remains eligible
under the evidence contract.

Eligibility also requires fresh evidence supplied by a future packet verifier.
That evidence identifies the asset, original URL, source fingerprint, stream,
exact source range and destination container, and includes codec parameters and
known geometry/color metadata. The verifier must establish exact packet cuts,
independently decodable starts, complete outgoing dependencies, exact timestamp
rebasing, codec delay/padding and container preservation. Codec names and FFprobe
keyframe flags alone cannot supply this proof. The caller is responsible for
checking that the evidence still describes the current original bytes.

The current importer supplies none of this packet evidence, so its metadata alone
produces an ineligible assessment. A successful assessment is conditional on the
verifier's assertions; it is not a guarantee that an output has been qualified.
Actual remuxing still needs decoded boundary-frame, timestamp, duration, sync and
packet-payload comparisons. Cuts-only concatenation, multiple whole audio streams,
and copying picture while rendering audio remain future work.

Run the core suite with `swift test --package-path Packages/EditorCore`. The
assessment tests cover missing and mismatched evidence, independent picture/audio
results, packet/dependency failures, geometry/rate changes and edited audio.
