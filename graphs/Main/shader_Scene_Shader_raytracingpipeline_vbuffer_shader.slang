#include "scene_legacy_callbacks.slang"
// The Default pipeline's raygen, starting from the visibility buffer: the raster first hit
// replaces the traced camera ray, then the same closest-hit and miss shading runs.
// Scene interface types are supplied by the shader manifest.
float3 SceneShaderVbufferMain(SceneContext scene, RayLaunch launch, inout RayQueryContext queries)
{
    ScenePayload payload = (ScenePayload)0;
    SurfaceHit hit;
    uint status = LoadVisibilitySurface(scene, launch, queries, hit);
    if (status == SCENE_QUERY_SURFACE)
        SceneShaderMain(scene, hit, queries, payload);
    else if (status == SCENE_QUERY_MISS)
        SceneShaderMain(scene, ShaderMain(launch), queries, payload);
    return payload.Radiance;
}
