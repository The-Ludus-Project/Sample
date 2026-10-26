// Ludus direct mesh-light estimator, using the original callback interface.
// Replace the original scene shader with this file; do not include both.
//
// Default proposal: emitter distance/orientation weighting, then triangle area
// sampling. New triangle-reservoir and centroid-emission proposals are opt-in.
// Set macros before this file or through compiler -D options.
//
// Required callback contracts:
// - Random floats are in [0, 1); random integers in [first, last).
// - TriangleIndex is a global ID; each emissive triangle belongs to one emitter.
// - GetTriangle and GetEmitterTriangle describe the same current world geometry.
// - GetEmitter.y is an integer triangle count; hierarchical area sampling needs
//   .z to equal the sum of their current world areas.
// - BSDF sampling/evaluation describe the same continuous reflection mixture.
//   EvaluateStandardBsdf returns f WITHOUT the cosine and the FULL mixture PDF.
// - GetMaterial supplies IsEmissionTwoSided; only EvaluateMaterial is required
//   to set MaterialSample.IsValid, as in the original shader.
// - BSDF/emission values are finite, nonnegative linear RGB.
// - A zero BSDF-sampled direction means an ordinary rejected sample.
// - The caller must handle queries.HasFailed; invalid samples are not valid black
//   samples to accumulate. This file does not define the caller's error policy.
//
// Scope retained: registered emissive meshes and continuous reflection. True
// delta scattering/transmission need a richer BSDF callback, not another macro.
// No alias table or light hierarchy is assumed by this callback-compatible file.
// Flat reservoir selection is still O(total emissive triangles).
//
// Suggested experiments (all use MIS/power unless overridden):
//   1. Default: original proposal with local work reduction.
//   2. -DLUDUS_EMITTER_SAMPLING_MODE=0             uniform emitter baseline
//   3. -DLUDUS_NEE_SAMPLING_MODE=1
//      -DLUDUS_NEE_TRIANGLE_WEIGHT_MODE=0         uniform positive-area triangle
//   4. Same, TRIANGLE_WEIGHT_MODE=1               uniform over all emissive area
//   5. Same, TRIANGLE_WEIGHT_MODE=2               spatial triangle importance
//   6. Experiment 5 + -DLUDUS_NEE_USE_EMISSION_PROXY=1
//   7. -DLUDUS_DIRECT_LIGHTING_MODE=0 / 1 / 2     light / BSDF / MIS
//
// MIS reference: https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer
// Reservoir reference: https://pbr-book.org/4ed/Sampling_Algorithms/Reservoir_Sampling

#include "scene_legacy_callbacks.slang"

#if defined(LUDUS_DEBUG_LIGHT_SOURCES) && !defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX_COLOR)
#define LUDUS_DEBUG_LIGHT_SOURCE_INDEX_COLOR
#endif

// Existing switches retain their values and meanings in hierarchical mode.
#define LUDUS_EMITTER_SAMPLING_MODE_UNIFORM (0)
#define LUDUS_EMITTER_SAMPLING_MODE_DISTANCE_WEIGHTED (1)
#ifndef LUDUS_EMITTER_SAMPLING_MODE
#define LUDUS_EMITTER_SAMPLING_MODE LUDUS_EMITTER_SAMPLING_MODE_DISTANCE_WEIGHTED
#endif
#ifndef LUDUS_EMITTER_SAMPLING_MODE_DISTANCE_WEIGHTED_ORIENTATION
#define LUDUS_EMITTER_SAMPLING_MODE_DISTANCE_WEIGHTED_ORIENTATION (1)
#endif

#define LUDUS_TRIANGLE_SAMPLING_MODE_UNIFORM (0)
#define LUDUS_TRIANGLE_SAMPLING_MODE_AREA_WEIGHTED (1)
#ifndef LUDUS_TRIANGLE_SAMPLING_MODE
#define LUDUS_TRIANGLE_SAMPLING_MODE LUDUS_TRIANGLE_SAMPLING_MODE_AREA_WEIGHTED
#endif

#define LUDUS_MIS_MODE_DISABLED (0)
#define LUDUS_MIS_MODE_POWER (1)
#define LUDUS_MIS_MODE_BALANCE (2)
#ifndef LUDUS_MIS_MODE
#define LUDUS_MIS_MODE LUDUS_MIS_MODE_POWER
#endif

// HIERARCHICAL means the original two-stage emitter -> triangle choice. It is
// not a BVH or other acceleration hierarchy.
#define LUDUS_NEE_SAMPLING_MODE_HIERARCHICAL (0)
#define LUDUS_NEE_SAMPLING_MODE_TRIANGLE_RESERVOIR (1)
#ifndef LUDUS_NEE_SAMPLING_MODE
#define LUDUS_NEE_SAMPLING_MODE LUDUS_NEE_SAMPLING_MODE_HIERARCHICAL
#endif

// These weights apply ONLY to TRIANGLE_RESERVOIR mode.
#define LUDUS_NEE_TRIANGLE_WEIGHT_MODE_UNIFORM (0)
#define LUDUS_NEE_TRIANGLE_WEIGHT_MODE_AREA (1)
#define LUDUS_NEE_TRIANGLE_WEIGHT_MODE_DISTANCE (2)
#ifndef LUDUS_NEE_TRIANGLE_WEIGHT_MODE
#define LUDUS_NEE_TRIANGLE_WEIGHT_MODE LUDUS_NEE_TRIANGLE_WEIGHT_MODE_DISTANCE
#endif

#define LUDUS_DIRECT_LIGHTING_MODE_LIGHT_ONLY (0)
#define LUDUS_DIRECT_LIGHTING_MODE_BSDF_ONLY (1)
#define LUDUS_DIRECT_LIGHTING_MODE_MIS (2)
#ifndef LUDUS_DIRECT_LIGHTING_MODE
#if LUDUS_MIS_MODE == LUDUS_MIS_MODE_DISABLED
#define LUDUS_DIRECT_LIGHTING_MODE LUDUS_DIRECT_LIGHTING_MODE_LIGHT_ONLY
#else
#define LUDUS_DIRECT_LIGHTING_MODE LUDUS_DIRECT_LIGHTING_MODE_MIS
#endif
#endif

// Applies only to DISTANCE importance weights (both proposal families). This
// is an expensive, directional CENTROID proxy, not integrated emitted power.
// Uniform/area modes remain literal uniform/area proposals.
#ifndef LUDUS_NEE_USE_EMISSION_PROXY
#define LUDUS_NEE_USE_EMISSION_PROXY (0)
#endif
#ifndef LUDUS_NEE_EMISSION_PROXY_FLOOR
#define LUDUS_NEE_EMISSION_PROXY_FLOOR (0.0001f)
#endif
#ifndef LUDUS_NEE_MINIMUM_DISTANCE_WORLD
#define LUDUS_NEE_MINIMUM_DISTANCE_WORLD (0.001f)
#endif
#ifndef LUDUS_NEE_ANGULAR_WEIGHT_FLOOR
#define LUDUS_NEE_ANGULAR_WEIGHT_FLOOR (0.001f)
#endif

// 0 preserves the original proposal normal. 1 uses the evaluated material's
// normal (e.g. normal mapping). Sampling and reverse PDF use the same choice.
#ifndef LUDUS_NEE_USE_MATERIAL_NORMAL
#define LUDUS_NEE_USE_MATERIAL_NORMAL (1)
#endif

// Set to 0 to reproduce the original emission-only surface behavior.
#ifndef LUDUS_EMISSIVE_SURFACES_REFLECT
#define LUDUS_EMISSIVE_SURFACES_REFLECT (1)
#endif

// Debug-only O(triangle count) check for stale totals before area-CDF sampling
// or evaluating its PDF. Disable for performance comparisons.
#ifndef LUDUS_NEE_VALIDATE_AREA_TOTALS
#define LUDUS_NEE_VALIDATE_AREA_TOTALS (0)
#endif
#ifndef LUDUS_NEE_AREA_TOTAL_RELATIVE_TOLERANCE
#define LUDUS_NEE_AREA_TOTAL_RELATIVE_TOLERANCE (0.0001f)
#endif

#if LUDUS_EMITTER_SAMPLING_MODE != 0 && LUDUS_EMITTER_SAMPLING_MODE != 1
#error "Invalid LUDUS_EMITTER_SAMPLING_MODE"
#endif
#if LUDUS_TRIANGLE_SAMPLING_MODE != 0 && LUDUS_TRIANGLE_SAMPLING_MODE != 1
#error "Invalid LUDUS_TRIANGLE_SAMPLING_MODE"
#endif
#if LUDUS_MIS_MODE < 0 || LUDUS_MIS_MODE > 2
#error "Invalid LUDUS_MIS_MODE"
#endif
#if LUDUS_NEE_SAMPLING_MODE != 0 && LUDUS_NEE_SAMPLING_MODE != 1
#error "Invalid LUDUS_NEE_SAMPLING_MODE"
#endif
#if LUDUS_NEE_TRIANGLE_WEIGHT_MODE < 0 || LUDUS_NEE_TRIANGLE_WEIGHT_MODE > 2
#error "Invalid LUDUS_NEE_TRIANGLE_WEIGHT_MODE"
#endif
#if LUDUS_DIRECT_LIGHTING_MODE < 0 || LUDUS_DIRECT_LIGHTING_MODE > 2
#error "Invalid LUDUS_DIRECT_LIGHTING_MODE"
#endif
#if LUDUS_DIRECT_LIGHTING_MODE == LUDUS_DIRECT_LIGHTING_MODE_MIS && LUDUS_MIS_MODE == LUDUS_MIS_MODE_DISABLED
#error "MIS requires POWER or BALANCE; use LIGHT_ONLY or BSDF_ONLY to disable MIS"
#endif
#if (LUDUS_NEE_USE_EMISSION_PROXY != 0 && LUDUS_NEE_USE_EMISSION_PROXY != 1) || (LUDUS_NEE_USE_MATERIAL_NORMAL != 0 && LUDUS_NEE_USE_MATERIAL_NORMAL != 1) || (LUDUS_EMISSIVE_SURFACES_REFLECT != 0 && LUDUS_EMISSIVE_SURFACES_REFLECT != 1) || (LUDUS_NEE_VALIDATE_AREA_TOTALS != 0 && LUDUS_NEE_VALIDATE_AREA_TOTALS != 1) || (LUDUS_EMITTER_SAMPLING_MODE_DISTANCE_WEIGHTED_ORIENTATION != 0 && LUDUS_EMITTER_SAMPLING_MODE_DISTANCE_WEIGHTED_ORIENTATION != 1)
#error "Boolean configuration macros must be 0 or 1"
#endif

struct LudusNeeState
{
    float TotalWeight;
    uint SelectedEmitterIndex;
    float SelectedEmitterPmf;
    bool HasEmitterSelection;
};

struct LudusNeeTriangleSample
{
    uint EmitterIndex;
    uint TriangleIndex;
    float PdfArea; // FULL joint area density, including all discrete choices.
    bool HasSample;
};

bool ValidateNonnegativeSpectrum(float3 value, inout RayQueryContext queries)
{
    if (all(isfinite(value)) == false || any(value < 0.0f))
    {
        queries.HasFailed = true;
        return false;
    }
    return true;
}

bool TryNormalizeDirection(float3 value, out float3 direction)
{
    direction = float3(0.0f);
    const float lengthSquared = dot(value, value);
    if (all(isfinite(value)) == false || isfinite(lengthSquared) == false || lengthSquared <= 0.0f)
    {
        return false;
    }
    direction = value * rsqrt(lengthSquared);
    return all(isfinite(direction));
}

bool ValidateTriangle(TriangleData triangle, inout RayQueryContext queries)
{
    // Zero-area triangles are valid zero-measure candidates; callers skip them.
    if (triangle.IsValid == false || isfinite(triangle.AreaWorld) == false || triangle.AreaWorld < 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    return true;
}

bool TryReadTriangleCount(float4 emitter, inout RayQueryContext queries, out uint count)
{
    count = 0u;
    if (isfinite(emitter.y) == false || emitter.y < 0.0f || emitter.y >= 4294967296.0f || floor(emitter.y) != emitter.y)
    {
        queries.HasFailed = true;
        return false;
    }
    count = uint(emitter.y);
    return true;
}

bool TryReadPositiveArea(float area, inout RayQueryContext queries)
{
    if (isfinite(area) == false || area < 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    return area > 0.0f;
}

bool ValidatePdf(float pdf, inout RayQueryContext queries)
{
    // A competing density of zero is valid.
    if (isfinite(pdf) == false || pdf < 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    return true;
}

bool TryReadRandom(inout RayQueryContext queries, out float value)
{
    value = SampleSceneRandom(queries);
    if (queries.HasFailed || isfinite(value) == false || value < 0.0f || value >= 1.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    return true;
}

bool IsEmitterInDomain(uint emitterIndex, uint emitterCount)
{
    if (emitterIndex >= emitterCount)
    {
        return false;
    }
#if defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX)
    return emitterIndex == uint(LUDUS_DEBUG_LIGHT_SOURCE_INDEX) % emitterCount;
#else
    return true;
#endif
}

#if defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX_COLOR)
float3 GetIndexColor(uint index)
{
    uint hash = index ^ 0x9E3779B9u;
    hash ^= hash >> 16u;
    hash *= 0x7FEB352Du;
    hash ^= hash >> 15u;
    hash *= 0x846CA68Bu;
    hash ^= hash >> 16u;
    return float3(uint3(hash, hash >> 8u, hash >> 16u) & 255u) / 255.0f;
}
#endif

// isEmissionTwoSided is GetMaterial(triangle.MaterialIndex).IsEmissionTwoSided,
// supplied by the caller so per-emitter loops can fetch the material once.
bool TryComputeTriangleImportance(
    SceneContext scene, TriangleData triangle, bool isEmissionTwoSided, float3 receiverPositionWorld,
    float3 samplingNormalWorld, inout RayQueryContext queries, out float importance)
{
    importance = 0.0f;
    const float minimumDistance = LUDUS_NEE_MINIMUM_DISTANCE_WORLD;
    const float angularFloor = LUDUS_NEE_ANGULAR_WEIGHT_FLOOR;
    if (isfinite(minimumDistance) == false || minimumDistance <= 0.0f ||
        isfinite(angularFloor) == false || angularFloor <= 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    const float minimumDistanceSquared = minimumDistance * minimumDistance;
    const float3 centerWorld =
        (triangle.Position0World + triangle.Position1World + triangle.Position2World) / 3.0f;
    const float3 offset0 = triangle.Position0World - centerWorld;
    const float3 offset1 = triangle.Position1World - centerWorld;
    const float3 offset2 = triangle.Position2World - centerWorld;
    const float radiusSquared = max(dot(offset0, offset0), max(dot(offset1, offset1), dot(offset2, offset2)));
    const float3 toEmitterWorld = centerWorld - receiverPositionWorld;
    const float distanceSquared = dot(toEmitterWorld, toEmitterWorld);
    if (all(isfinite(centerWorld)) == false || isfinite(radiusSquared) == false ||
        isfinite(distanceSquared) == false || isfinite(minimumDistanceSquared) == false || minimumDistanceSquared <= 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    float angularWeight = 1.0f;
    float3 directionWorld = float3(0.0f);
    const bool hasDirection = distanceSquared > minimumDistanceSquared;
    if (hasDirection)
    {
        directionWorld = toEmitterWorld * rsqrt(distanceSquared);
    }
#if LUDUS_EMITTER_SAMPLING_MODE_DISTANCE_WEIGHTED_ORIENTATION
    if (hasDirection)
    {
        float3 emitterNormalWorld;
        if (TryNormalizeDirection(triangle.GeometricNormalWorld, emitterNormalWorld) == false)
        {
            queries.HasFailed = true;
            return false;
        }
        const float cosSurface = max(dot(samplingNormalWorld, directionWorld), 0.0f);
        const float facing = dot(emitterNormalWorld, -directionWorld);
        const float cosEmitter = isEmissionTwoSided ? abs(facing) : max(facing, 0.0f);
        angularWeight = max(cosSurface * cosEmitter, angularFloor);
    }
#endif
    importance = angularWeight / max(distanceSquared, max(radiusSquared, minimumDistanceSquared));
#if LUDUS_NEE_USE_EMISSION_PROXY
    const float emissionFloor = LUDUS_NEE_EMISSION_PROXY_FLOOR;
    if (isfinite(emissionFloor) == false || emissionFloor <= 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    const SurfaceHit centerHit = GetSurfaceHit(scene, triangle.TriangleIndex, float2(1.0f / 3.0f));
    if (centerHit.IsValid == false)
    {
        queries.HasFailed = true;
        return false;
    }
    float3 emissionDirection = -directionWorld;
    if (hasDirection == false && TryNormalizeDirection(triangle.GeometricNormalWorld, emissionDirection) == false)
    {
        queries.HasFailed = true;
        return false;
    }
    const float3 emission = EvaluateEmission(scene, centerHit, emissionDirection);
    if (ValidateNonnegativeSpectrum(emission, queries) == false)
    {
        return false;
    }
    // max-channel intensity avoids assuming a particular RGB color space.
    // The positive floor retains support for emission away from the centroid.
    importance *= max(max(emission.x, max(emission.y, emission.z)), emissionFloor);
#endif
    if (isfinite(importance) == false || importance <= 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    return true;
}

bool TryComputeEmitterWeight(
    SceneContext scene, uint emitterIndex, float3 receiverPositionWorld,
    float3 samplingNormalWorld, inout RayQueryContext queries, out float weight)
{
    weight = 0.0f;
    uint triangleCount;
    if (TryReadTriangleCount(GetEmitter(scene, emitterIndex), queries, triangleCount) == false)
    {
        return false;
    }
    // An emitter's triangles normally share one material: refetch only when the
    // index changes, keeping a dependent material load out of the per-triangle path.
    uint cachedMaterialIndex = 0xFFFFFFFFu;
    bool isEmissionTwoSided = false;
    for (uint i = 0u; i < triangleCount; ++i)
    {
        const TriangleData triangle = GetEmitterTriangle(scene, emitterIndex, i);
        if (ValidateTriangle(triangle, queries) == false)
        {
            return false;
        }
        if (triangle.AreaWorld == 0.0f)
        {
            continue;
        }
#if LUDUS_EMITTER_SAMPLING_MODE_DISTANCE_WEIGHTED_ORIENTATION
        if (triangle.MaterialIndex != cachedMaterialIndex)
        {
            isEmissionTwoSided = GetMaterial(scene, triangle.MaterialIndex).IsEmissionTwoSided;
            cachedMaterialIndex = triangle.MaterialIndex;
        }
#endif
        float importance;
        if (TryComputeTriangleImportance(scene, triangle, isEmissionTwoSided, receiverPositionWorld, samplingNormalWorld, queries, importance) == false)
        {
            return false;
        }
        const float triangleWeight = triangle.AreaWorld * importance;
        weight += triangleWeight;
        if (isfinite(triangleWeight) == false || triangleWeight <= 0.0f || isfinite(weight) == false)
        {
            queries.HasFailed = true;
            return false;
        }
    }
    return true;
}

bool TryUpdateReservoir(
    float weight, inout float totalWeight, inout RayQueryContext queries, out bool replace)
{
    replace = false;
    if (isfinite(weight) == false || weight <= 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    const bool isFirst = totalWeight == 0.0f;
    totalWeight += weight;
    if (isfinite(totalWeight) == false)
    {
        queries.HasFailed = true;
        return false;
    }
    if (isFirst)
    {
        replace = true; // Probability one: no random draw is needed.
        return true;
    }
    float randomValue;
    if (TryReadRandom(queries, randomValue) == false)
    {
        return false;
    }
    replace = randomValue < weight / totalWeight;
    return true;
}

bool TrySelectEmitter(
    SceneContext scene, float3 receiverPositionWorld, float3 samplingNormalWorld,
    inout RayQueryContext queries, out LudusNeeState state)
{
    state = (LudusNeeState)0;
    const uint emitterCount = GetEmitterCount(scene);
    if (emitterCount == 0u)
    {
        return false;
    }
#if defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX)
    state.SelectedEmitterIndex = uint(LUDUS_DEBUG_LIGHT_SOURCE_INDEX) % emitterCount;
    state.SelectedEmitterPmf = 1.0f;
    state.TotalWeight = 1.0f;
#else
    if (emitterCount == 1u)
    {
        state.SelectedEmitterIndex = 0u;
        state.SelectedEmitterPmf = 1.0f;
        state.TotalWeight = 1.0f;
        state.HasEmitterSelection = true;
        return true;
    }
#if LUDUS_EMITTER_SAMPLING_MODE == LUDUS_EMITTER_SAMPLING_MODE_UNIFORM
    state.SelectedEmitterIndex = SampleSceneRandom(queries, 0u, emitterCount);
    if (queries.HasFailed || state.SelectedEmitterIndex >= emitterCount)
    {
        queries.HasFailed = true;
        return false;
    }
    state.SelectedEmitterPmf = 1.0f / float(emitterCount);
    state.TotalWeight = float(emitterCount);
#else
    float selectedWeight = 0.0f;
    for (uint i = 0u; i < emitterCount; ++i)
    {
        float weight;
        if (TryComputeEmitterWeight(scene, i, receiverPositionWorld, samplingNormalWorld, queries, weight) == false)
        {
            return false;
        }
        if (weight == 0.0f)
        {
            continue;
        }
        bool replace;
        if (TryUpdateReservoir(weight, state.TotalWeight, queries, replace) == false)
        {
            return false;
        }
        if (replace)
        {
            state.SelectedEmitterIndex = i;
            selectedWeight = weight;
        }
    }
    if (selectedWeight == 0.0f)
    {
        return false;
    }
    state.SelectedEmitterPmf = selectedWeight / state.TotalWeight;
#endif
#endif
    state.HasEmitterSelection = true;
    return queries.HasFailed == false;
}

float EvaluateEmitterSelectionPmf(
    SceneContext scene, float3 receiverPositionWorld, float3 samplingNormalWorld,
    uint emitterIndex, LudusNeeState state, inout RayQueryContext queries)
{
    const uint emitterCount = GetEmitterCount(scene);
    if (IsEmitterInDomain(emitterIndex, emitterCount) == false)
    {
        return 0.0f;
    }
#if defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX)
    return 1.0f;
#else
    if (emitterCount == 1u)
    {
        return 1.0f;
    }
#if LUDUS_EMITTER_SAMPLING_MODE == LUDUS_EMITTER_SAMPLING_MODE_UNIFORM
    return 1.0f / float(emitterCount);
#else
    if (state.HasEmitterSelection && emitterIndex == state.SelectedEmitterIndex)
    {
        return state.SelectedEmitterPmf; // Reuse the exact selected-emitter PMF.
    }
    if (state.TotalWeight <= 0.0f)
    {
        return 0.0f;
    }
    float weight;
    if (TryComputeEmitterWeight(scene, emitterIndex, receiverPositionWorld, samplingNormalWorld, queries, weight) == false)
    {
        return 0.0f;
    }
    return weight / state.TotalWeight;
#endif
#endif
}

bool ValidateEmitterAreaTotal(
    SceneContext scene, uint emitterIndex, uint triangleCount, float totalArea,
    inout RayQueryContext queries)
{
    if (isfinite(totalArea) == false || totalArea < 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
#if LUDUS_NEE_VALIDATE_AREA_TOTALS
    float accumulatedArea = 0.0f;
    for (uint i = 0u; i < triangleCount; ++i)
    {
        const TriangleData triangle = GetEmitterTriangle(scene, emitterIndex, i);
        if (ValidateTriangle(triangle, queries) == false)
        {
            return false;
        }
        accumulatedArea += triangle.AreaWorld;
    }
    const float tolerance = LUDUS_NEE_AREA_TOTAL_RELATIVE_TOLERANCE;
    if (isfinite(accumulatedArea) == false || isfinite(tolerance) == false || tolerance < 0.0f ||
        abs(accumulatedArea - totalArea) > tolerance * max(accumulatedArea, totalArea))
    {
        queries.HasFailed = true;
        return false;
    }
#endif
    return true;
}

bool TrySampleEmitterTriangle(
    SceneContext scene, LudusNeeState state, inout RayQueryContext queries,
    out LudusNeeTriangleSample sample)
{
    sample = (LudusNeeTriangleSample)0;
    const float4 emitter = GetEmitter(scene, state.SelectedEmitterIndex);
    uint triangleCount;
    if (TryReadTriangleCount(emitter, queries, triangleCount) == false || triangleCount == 0u)
    {
        return false;
    }
    TriangleData triangle = (TriangleData)0;
#if LUDUS_TRIANGLE_SAMPLING_MODE == LUDUS_TRIANGLE_SAMPLING_MODE_UNIFORM
    const uint localIndex = SampleSceneRandom(queries, 0u, triangleCount);
    if (queries.HasFailed || localIndex >= triangleCount)
    {
        queries.HasFailed = true;
        return false;
    }
    triangle = GetEmitterTriangle(scene, state.SelectedEmitterIndex, localIndex);
    if (ValidateTriangle(triangle, queries) == false || triangle.AreaWorld == 0.0f)
    {
        return false;
    }
    sample.PdfArea = (state.SelectedEmitterPmf / float(triangleCount)) / triangle.AreaWorld;
#else
    if (ValidateEmitterAreaTotal(scene, state.SelectedEmitterIndex, triangleCount, emitter.z, queries) == false ||
        TryReadPositiveArea(emitter.z, queries) == false)
    {
        return false;
    }
    float randomValue;
    if (TryReadRandom(queries, randomValue) == false)
    {
        return false;
    }
    const float targetArea = randomValue * emitter.z;
    float cumulativeArea = 0.0f;
    for (uint i = 0u; i < triangleCount; ++i)
    {
        const TriangleData candidate = GetEmitterTriangle(scene, state.SelectedEmitterIndex, i);
        if (ValidateTriangle(candidate, queries) == false)
        {
            return false;
        }
        if (candidate.AreaWorld == 0.0f)
        {
            continue;
        }
        triangle = candidate;
        cumulativeArea += candidate.AreaWorld;
        if (isfinite(cumulativeArea) == false)
        {
            queries.HasFailed = true;
            return false;
        }
        if (targetArea < cumulativeArea)
        {
            break;
        }
    }
    // Last positive-area candidate handles only cumulative-rounding error.
    // The scene-data invariant, optionally checked above, is still required.
    if (triangle.IsValid == false)
    {
        queries.HasFailed = true;
        return false;
    }
    sample.PdfArea = state.SelectedEmitterPmf / emitter.z;
#endif
    if (ValidatePdf(sample.PdfArea, queries) == false || sample.PdfArea == 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    sample.EmitterIndex = state.SelectedEmitterIndex;
    sample.TriangleIndex = triangle.TriangleIndex;
    sample.HasSample = true;
    return true;
}

bool TryComputeReservoirTriangleWeight(
    SceneContext scene, TriangleData triangle, float3 receiverPositionWorld,
    float3 samplingNormalWorld, inout RayQueryContext queries,
    out float weight, out float importance)
{
    importance = 1.0f;
#if LUDUS_NEE_TRIANGLE_WEIGHT_MODE == LUDUS_NEE_TRIANGLE_WEIGHT_MODE_UNIFORM
    weight = 1.0f;
#elif LUDUS_NEE_TRIANGLE_WEIGHT_MODE == LUDUS_NEE_TRIANGLE_WEIGHT_MODE_AREA
    weight = triangle.AreaWorld;
#else
    weight = 0.0f;
    bool isEmissionTwoSided = false;
#if LUDUS_EMITTER_SAMPLING_MODE_DISTANCE_WEIGHTED_ORIENTATION
    isEmissionTwoSided = GetMaterial(scene, triangle.MaterialIndex).IsEmissionTwoSided;
#endif
    if (TryComputeTriangleImportance(scene, triangle, isEmissionTwoSided, receiverPositionWorld, samplingNormalWorld, queries, importance) == false)
    {
        return false;
    }
    weight = triangle.AreaWorld * importance;
#endif
    if (isfinite(weight) == false || weight <= 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    return true;
}

float ComputeReservoirTrianglePdfArea(float totalWeight, float triangleArea, float importance)
{
    if (totalWeight <= 0.0f)
    {
        return 0.0f;
    }
    // These are all q_t / A_t. The simplified expressions avoid multiplying
    // large denominators and cancel the area analytically where appropriate.
#if LUDUS_NEE_TRIANGLE_WEIGHT_MODE == LUDUS_NEE_TRIANGLE_WEIGHT_MODE_UNIFORM
    return (1.0f / totalWeight) / triangleArea;
#elif LUDUS_NEE_TRIANGLE_WEIGHT_MODE == LUDUS_NEE_TRIANGLE_WEIGHT_MODE_AREA
    return 1.0f / totalWeight;
#else
    return importance / totalWeight;
#endif
}

bool TrySampleTriangleReservoir(
    SceneContext scene, float3 receiverPositionWorld, float3 samplingNormalWorld,
    inout RayQueryContext queries, out LudusNeeState state,
    out LudusNeeTriangleSample sample)
{
    state = (LudusNeeState)0;
    sample = (LudusNeeTriangleSample)0;
    const uint emitterCount = GetEmitterCount(scene);
    if (emitterCount == 0u)
    {
        return false;
    }
    uint firstEmitter = 0u;
    uint endEmitter = emitterCount;
#if defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX)
    firstEmitter = uint(LUDUS_DEBUG_LIGHT_SOURCE_INDEX) % emitterCount;
    endEmitter = firstEmitter + 1u;
#endif
    float selectedArea = 0.0f;
    float selectedImportance = 0.0f;
    for (uint e = firstEmitter; e < endEmitter; ++e)
    {
        uint triangleCount;
        if (TryReadTriangleCount(GetEmitter(scene, e), queries, triangleCount) == false)
        {
            return false;
        }
        for (uint i = 0u; i < triangleCount; ++i)
        {
            const TriangleData triangle = GetEmitterTriangle(scene, e, i);
            if (ValidateTriangle(triangle, queries) == false)
            {
                return false;
            }
            if (triangle.AreaWorld == 0.0f)
            {
                continue;
            }
            float weight;
            float importance;
            if (TryComputeReservoirTriangleWeight(scene, triangle, receiverPositionWorld, samplingNormalWorld, queries, weight, importance) == false)
            {
                return false;
            }
            bool replace;
            if (TryUpdateReservoir(weight, state.TotalWeight, queries, replace) == false)
            {
                return false;
            }
            if (replace)
            {
                sample.EmitterIndex = e;
                sample.TriangleIndex = triangle.TriangleIndex;
                selectedArea = triangle.AreaWorld;
                selectedImportance = importance;
                sample.HasSample = true;
            }
        }
    }
    if (sample.HasSample == false)
    {
        return false;
    }
    sample.PdfArea = ComputeReservoirTrianglePdfArea(state.TotalWeight, selectedArea, selectedImportance);
    if (ValidatePdf(sample.PdfArea, queries) == false || sample.PdfArea == 0.0f)
    {
        queries.HasFailed = true;
        return false;
    }
    return true;
}

bool TryPrepareNeeSample(
    SceneContext scene, float3 receiverPositionWorld, float3 samplingNormalWorld,
    inout RayQueryContext queries, out LudusNeeState state,
    out LudusNeeTriangleSample sample)
{
#if LUDUS_NEE_SAMPLING_MODE == LUDUS_NEE_SAMPLING_MODE_TRIANGLE_RESERVOIR
    return TrySampleTriangleReservoir(scene, receiverPositionWorld, samplingNormalWorld, queries, state, sample);
#else
    sample = (LudusNeeTriangleSample)0;
    if (TrySelectEmitter(scene, receiverPositionWorld, samplingNormalWorld, queries, state) == false)
    {
        return false;
    }
    // State remains valid even if triangle selection returns a legitimate zero.
    return TrySampleEmitterTriangle(scene, state, queries, sample);
#endif
}

float EvaluateNeePdfArea(
    SceneContext scene, float3 receiverPositionWorld, float3 samplingNormalWorld,
    SurfaceHit endpoint, LudusNeeState state, inout RayQueryContext queries)
{
    if (IsEmitterInDomain(endpoint.EmitterIndex, GetEmitterCount(scene)) == false)
    {
        return 0.0f;
    }
#if LUDUS_NEE_SAMPLING_MODE == LUDUS_NEE_SAMPLING_MODE_TRIANGLE_RESERVOIR
    if (state.TotalWeight <= 0.0f)
    {
        return 0.0f;
    }
    const TriangleData triangle = GetTriangle(scene, endpoint.TriangleIndex);
    if (ValidateTriangle(triangle, queries) == false || triangle.AreaWorld == 0.0f)
    {
        return 0.0f;
    }
    float weight;
    float importance;
    if (TryComputeReservoirTriangleWeight(scene, triangle, receiverPositionWorld, samplingNormalWorld, queries, weight, importance) == false)
    {
        return 0.0f;
    }
    return ComputeReservoirTrianglePdfArea(state.TotalWeight, triangle.AreaWorld, importance);
#else
    const float emitterPmf = EvaluateEmitterSelectionPmf(scene, receiverPositionWorld, samplingNormalWorld, endpoint.EmitterIndex, state, queries);
    if (emitterPmf <= 0.0f || queries.HasFailed)
    {
        return 0.0f;
    }
    const float4 emitter = GetEmitter(scene, endpoint.EmitterIndex);
#if LUDUS_TRIANGLE_SAMPLING_MODE == LUDUS_TRIANGLE_SAMPLING_MODE_AREA_WEIGHTED
#if LUDUS_NEE_VALIDATE_AREA_TOTALS
    uint triangleCount;
    if (TryReadTriangleCount(emitter, queries, triangleCount) == false ||
        ValidateEmitterAreaTotal(scene, endpoint.EmitterIndex, triangleCount, emitter.z, queries) == false)
    {
        return 0.0f;
    }
#endif
    if (TryReadPositiveArea(emitter.z, queries) == false)
    {
        return 0.0f;
    }
    return emitterPmf / emitter.z;
#else
    uint triangleCount;
    const TriangleData triangle = GetTriangle(scene, endpoint.TriangleIndex);
    if (TryReadTriangleCount(emitter, queries, triangleCount) == false || triangleCount == 0u ||
        ValidateTriangle(triangle, queries) == false || triangle.AreaWorld == 0.0f)
    {
        return 0.0f;
    }
    return (emitterPmf / float(triangleCount)) / triangle.AreaWorld;
#endif
#endif
}

float ComputeDirectLightingMisWeight(float sampledPdf, float otherPdf)
{
    if (sampledPdf <= 0.0f)
    {
        return 0.0f;
    }
    if (otherPdf <= 0.0f)
    {
        return 1.0f;
    }
    const float maximumPdf = max(sampledPdf, otherPdf);
    const float sampled = sampledPdf / maximumPdf;
    const float other = otherPdf / maximumPdf;
#if LUDUS_MIS_MODE == LUDUS_MIS_MODE_BALANCE
    return sampled / (sampled + other);
#else
    return (sampled * sampled) / (sampled * sampled + other * other);
#endif
}

float ComputeNeeMisWeight(
    float lightPdfArea, float bsdfPdfSolidAngle, float distanceSquared,
    float cosEmitter, bool isLightSample)
{
#if LUDUS_DIRECT_LIGHTING_MODE != LUDUS_DIRECT_LIGHTING_MODE_MIS
    return 1.0f;
#else
    if (lightPdfArea == 0.0f)
    {
        return isLightSample ? 0.0f : 1.0f;
    }
    if (bsdfPdfSolidAngle == 0.0f)
    {
        return isLightSample ? 1.0f : 0.0f;
    }
    // Both densities are multiplied by the SAME positive factor. Choose a
    // factor <= 1 to avoid overflowing pA * distanceSquared / cosEmitter.
    // Thus this is exactly the same balance/power heuristic in real arithmetic.
    float lightPdf;
    float bsdfPdf;
    if (distanceSquared >= cosEmitter)
    {
        lightPdf = lightPdfArea;
        bsdfPdf = bsdfPdfSolidAngle * (cosEmitter / distanceSquared);
    }
    else
    {
        lightPdf = lightPdfArea * (distanceSquared / cosEmitter);
        bsdfPdf = bsdfPdfSolidAngle;
    }
    return isLightSample
        ? ComputeDirectLightingMisWeight(lightPdf, bsdfPdf)
        : ComputeDirectLightingMisWeight(bsdfPdf, lightPdf);
#endif
}

float3 SampleEmitterDirectLighting(
    SceneContext scene, SurfaceHit receiver, MaterialSample material,
    float3 shadingNormalWorld, float3 viewDirectionWorld,
    LudusNeeTriangleSample sample, inout RayQueryContext queries)
{
    float u;
    float v;
    if (TryReadRandom(queries, u) == false || TryReadRandom(queries, v) == false)
    {
        return float3(0.0f);
    }
    const float root = sqrt(u);
    const float2 barycentric = float2(root * (1.0f - v), root * v);
    const SurfaceHit endpoint = GetSurfaceHit(scene, sample.TriangleIndex, barycentric);
    if (endpoint.IsValid == false)
    {
        queries.HasFailed = true;
        return float3(0.0f);
    }
    const float3 offsetWorld = endpoint.PositionWorld - receiver.PositionWorld;
    const float distanceSquared = dot(offsetWorld, offsetWorld);
    if (isfinite(distanceSquared) == false)
    {
        queries.HasFailed = true;
        return float3(0.0f);
    }
    if (distanceSquared <= 0.0f)
    {
        return float3(0.0f);
    }
    const float distanceWorld = sqrt(distanceSquared);
    const float3 directionWorld = offsetWorld / distanceWorld;
    const float cosSurface = max(dot(shadingNormalWorld, directionWorld), 0.0f);
    if (cosSurface <= 0.0f)
    {
        return float3(0.0f);
    }
    float3 emitterNormalWorld;
    if (TryNormalizeDirection(endpoint.GeometricNormalWorld, emitterNormalWorld) == false)
    {
        queries.HasFailed = true;
        return float3(0.0f);
    }
    const float cosEmitter = abs(dot(emitterNormalWorld, -directionWorld));
    if (cosEmitter <= 0.0f)
    {
        return float3(0.0f);
    }
    const float3 emission = EvaluateEmission(scene, endpoint, -directionWorld);
    if (ValidateNonnegativeSpectrum(emission, queries) == false || any(emission > 0.0f) == false)
    {
        return float3(0.0f);
    }
    float3 bsdfValue;
    float bsdfPdf;
    EvaluateStandardBsdf(material, viewDirectionWorld, directionWorld, bsdfValue, bsdfPdf);
    if (ValidateNonnegativeSpectrum(bsdfValue, queries) == false || ValidatePdf(bsdfPdf, queries) == false ||
        any(bsdfValue > 0.0f) == false)
    {
        return float3(0.0f);
    }
    const float misWeight = ComputeNeeMisWeight(sample.PdfArea, bsdfPdf, distanceSquared, cosEmitter, true);
    if (misWeight == 0.0f)
    {
        return float3(0.0f);
    }
    LightSample lightSample = (LightSample)0;
    lightSample.TriangleIndex = sample.TriangleIndex;
    lightSample.Barycentric = barycentric;
    lightSample.PositionWorld = endpoint.PositionWorld;
    lightSample.DirectionWorld = directionWorld;
    lightSample.DistanceWorld = distanceWorld;
    lightSample.HasFiniteEndpoint = true;
    lightSample.HasSample = true;
    if (TestVisibility(scene, queries, receiver, lightSample) != SCENE_QUERY_MISS)
    {
        return float3(0.0f);
    }
    // Evaluate in area measure: f * Le * cosSurface * cosEmitter / (r^2 * pA).
    // Order the two divisors so large-distance cases avoid a large intermediate.
    float factor = cosSurface * cosEmitter * misWeight;
    if (distanceSquared >= 1.0f)
    {
        factor = (factor / distanceSquared) / sample.PdfArea;
    }
    else
    {
        factor = (factor / sample.PdfArea) / distanceSquared;
    }
    const float3 contribution = emission * bsdfValue * factor;
    if (ValidateNonnegativeSpectrum(contribution, queries) == false)
    {
        return float3(0.0f);
    }
    return contribution;
}

float3 SampleBsdfDirectLighting(
    SceneContext scene, SurfaceHit receiver, MaterialSample material,
    float3 shadingNormalWorld, float3 samplingNormalWorld, float3 viewDirectionWorld,
    LudusNeeState state, inout RayQueryContext queries)
{
    float sampleLobe;
    float sampleRadius;
    float sampleAngle;
    if (TryReadRandom(queries, sampleLobe) == false || TryReadRandom(queries, sampleRadius) == false ||
        TryReadRandom(queries, sampleAngle) == false)
    {
        return float3(0.0f);
    }
    const float3 sampledDirection = SampleStandardBsdf(material, viewDirectionWorld, float3(sampleLobe, sampleRadius, sampleAngle));
    if (all(isfinite(sampledDirection)) == false)
    {
        queries.HasFailed = true;
        return float3(0.0f);
    }
    if (all(sampledDirection == float3(0.0f)))
    {
        return float3(0.0f); // Explicit rejection convention of this interface.
    }
    float3 directionWorld;
    if (TryNormalizeDirection(sampledDirection, directionWorld) == false)
    {
        queries.HasFailed = true;
        return float3(0.0f);
    }
    const float cosSurface = max(dot(shadingNormalWorld, directionWorld), 0.0f);
    if (cosSurface <= 0.0f)
    {
        return float3(0.0f);
    }
    float3 bsdfValue;
    float bsdfPdf;
    EvaluateStandardBsdf(material, viewDirectionWorld, directionWorld, bsdfValue, bsdfPdf);
    if (ValidateNonnegativeSpectrum(bsdfValue, queries) == false || ValidatePdf(bsdfPdf, queries) == false ||
        any(bsdfValue > 0.0f) == false)
    {
        return float3(0.0f);
    }
    if (bsdfPdf == 0.0f)
    {
        // A nonzero accepted continuous BSDF sample must have positive density.
        queries.HasFailed = true;
        return float3(0.0f);
    }
    const float maximumTraceDistanceWorld = 3.402823466e38f;
    const Ray ray = SpawnSurfaceRay(receiver, directionWorld, maximumTraceDistanceWorld);
    SurfaceHit endpoint;
    if (TraceClosest(scene, queries, ray, endpoint) != SCENE_QUERY_SURFACE)
    {
        return float3(0.0f);
    }
    // SCENE_QUERY_SURFACE is the trace callback's success contract; unlike
    // GetSurfaceHit, the original code did not require its IsValid field.
    if (IsEmitterInDomain(endpoint.EmitterIndex, GetEmitterCount(scene)) == false)
    {
        return float3(0.0f);
    }
    const float3 emission = EvaluateEmission(scene, endpoint, -directionWorld);
    if (ValidateNonnegativeSpectrum(emission, queries) == false || any(emission > 0.0f) == false)
    {
        return float3(0.0f);
    }
    float misWeight = 1.0f;
#if LUDUS_DIRECT_LIGHTING_MODE == LUDUS_DIRECT_LIGHTING_MODE_MIS
    const float lightPdfArea = EvaluateNeePdfArea(scene, receiver.PositionWorld, samplingNormalWorld, endpoint, state, queries);
    if (queries.HasFailed || ValidatePdf(lightPdfArea, queries) == false)
    {
        return float3(0.0f);
    }
    if (lightPdfArea > 0.0f)
    {
        // Use the original receiver point, as the light proposal does; spawning
        // a robustly offset ray must not change the proposal's geometric PDF.
        const float3 offsetWorld = endpoint.PositionWorld - receiver.PositionWorld;
        const float distanceSquared = dot(offsetWorld, offsetWorld);
        float3 endpointDirection;
        float3 emitterNormalWorld;
        if (isfinite(distanceSquared) == false || distanceSquared <= 0.0f ||
            TryNormalizeDirection(offsetWorld, endpointDirection) == false ||
            TryNormalizeDirection(endpoint.GeometricNormalWorld, emitterNormalWorld) == false)
        {
            queries.HasFailed = true;
            return float3(0.0f);
        }
        const float cosEmitter = abs(dot(emitterNormalWorld, -endpointDirection));
        if (cosEmitter <= 0.0f)
        {
            return float3(0.0f);
        }
        misWeight = ComputeNeeMisWeight(lightPdfArea, bsdfPdf, distanceSquared, cosEmitter, false);
    }
#endif
    const float3 contribution = emission * bsdfValue * (cosSurface * misWeight / bsdfPdf);
    if (ValidateNonnegativeSpectrum(contribution, queries) == false)
    {
        return float3(0.0f);
    }
    return contribution;
}

void SceneShaderMain(
    SceneContext scene, SurfaceHit hit, inout RayQueryContext queries, inout ScenePayload payload)
{
    payload.Radiance = float3(0.0f);
    if (queries.HasFailed)
    {
        return;
    }
    float3 viewDirectionWorld;
    if (TryNormalizeDirection(-hit.IncomingRay.DirectionWorld, viewDirectionWorld) == false)
    {
        queries.HasFailed = true;
        return;
    }
    // Evaluate the (textured) material once. The emission below is exactly what
    // EvaluateEmission(scene, hit, viewDirectionWorld) returns, without its second
    // EvaluateMaterial call.
    const MaterialSample material = EvaluateMaterial(scene, hit);
    const float3 surfaceEmission =
        material.IsValid && (material.IsEmissionTwoSided || dot(hit.GeometricNormalWorld, viewDirectionWorld) > 0.0f)
            ? material.Emission
            : float3(0.0f);
    if (ValidateNonnegativeSpectrum(surfaceEmission, queries) == false)
    {
        return;
    }
    payload.Radiance = surfaceEmission;
#if defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX_COLOR)
    if (any(surfaceEmission > 0.0f) && hit.EmitterIndex < GetEmitterCount(scene))
    {
        payload.Radiance = GetIndexColor(hit.EmitterIndex);
        return;
    }
#endif
#if !LUDUS_EMISSIVE_SURFACES_REFLECT
    if (any(surfaceEmission > 0.0f))
    {
        return;
    }
#endif
    if (GetEmitterCount(scene) == 0u)
    {
        return;
    }
    if (material.IsValid == false)
    {
        return;
    }
    float3 shadingNormalWorld;
    if (TryNormalizeDirection(material.ShadingNormalWorld, shadingNormalWorld) == false)
    {
        queries.HasFailed = true;
        return;
    }
    float3 samplingNormalWorld = shadingNormalWorld;
#if LUDUS_DIRECT_LIGHTING_MODE != LUDUS_DIRECT_LIGHTING_MODE_BSDF_ONLY || defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX_COLOR)
#if !LUDUS_NEE_USE_MATERIAL_NORMAL
    if (TryNormalizeDirection(hit.ShadingNormalWorld, samplingNormalWorld) == false)
    {
        queries.HasFailed = true;
        return;
    }
#endif
#endif
    LudusNeeState state = (LudusNeeState)0;
    LudusNeeTriangleSample sample = (LudusNeeTriangleSample)0;
#if LUDUS_DIRECT_LIGHTING_MODE != LUDUS_DIRECT_LIGHTING_MODE_BSDF_ONLY || defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX_COLOR)
    TryPrepareNeeSample(scene, hit.PositionWorld, samplingNormalWorld, queries, state, sample);
    if (queries.HasFailed)
    {
        return;
    }
#endif
#if defined(LUDUS_DEBUG_LIGHT_SOURCE_INDEX_COLOR)
    payload.Radiance = sample.HasSample ? GetIndexColor(sample.EmitterIndex) : float3(0.0f);
#else
    float3 directRadiance = float3(0.0f);
#if LUDUS_DIRECT_LIGHTING_MODE != LUDUS_DIRECT_LIGHTING_MODE_BSDF_ONLY
    if (sample.HasSample)
    {
        directRadiance = SampleEmitterDirectLighting(scene, hit, material, shadingNormalWorld, viewDirectionWorld, sample, queries);
    }
    if (queries.HasFailed)
    {
        return;
    }
#endif
#if LUDUS_DIRECT_LIGHTING_MODE != LUDUS_DIRECT_LIGHTING_MODE_LIGHT_ONLY
    // Run independently of the NEE sample's visibility or zero contribution.
    directRadiance += SampleBsdfDirectLighting(scene, hit, material, shadingNormalWorld, samplingNormalWorld, viewDirectionWorld, state, queries);
    if (queries.HasFailed)
    {
        return;
    }
#endif
    const float3 radiance = surfaceEmission + directRadiance;
    if (ValidateNonnegativeSpectrum(radiance, queries) == false)
    {
        return;
    }
    payload.Radiance = radiance; // Sum complementary MIS estimates; do not average.
#endif
}
