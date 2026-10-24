// Direct lighting at the visibility-buffer primary hit, using the same mesh-light
// estimator as the Default ray pipeline. Direct lighting only, two MIS strategies:
// - light sample: a point on an emitter, emission evaluated here, one occlusion
//   query (TestVisibility);
// - BSDF sample: one closest-hit query (TraceClosest); an emitter hit adds its
//   emission, any other hit or miss adds nothing and the sample ends.
// Both run in this stage; no closest-hit/miss callback is invoked.
// Lives at the graph root: build includes resolve beside the including file and
// may not use "..", so this is the only place that can reach the estimator.
#define LUDUS_DIRECT_LIGHTING_MODE LUDUS_DIRECT_LIGHTING_MODE_MIS
// Enter through the #pragma once header; it includes the estimator, which includes it back.
#include "scene_legacy_callbacks.slang"

float3 GenerateRay(SceneContext scene, RayLaunch launch, inout RayQueryContext inoutQueries)
{
    SurfaceHit hit;
    uint status = LoadVisibilitySurface(scene, launch, inoutQueries, hit);
    if (status == SCENE_QUERY_MISS)
        return EvaluateEnvironment(scene, launch.CameraRay.DirectionWorld);
    if (status != SCENE_QUERY_SURFACE)
        return float3(0);

    // Surface emission + MIS-weighted light and BSDF estimates, summed.
    ScenePayload payload = (ScenePayload)0;
    SceneShaderMain(scene, hit, inoutQueries, payload);
    return payload.Radiance;
}
