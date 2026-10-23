#include "scene_legacy_callbacks.slang"
// Edit this shader, then Save to publish it to the project.
// Scene interface types are supplied by the shader manifest.
float3 SceneShaderMain(SceneContext scene, RayLaunch launch, inout RayQueryContext queries)
{
    // The visibility buffer supplies the primary hit; only secondary rays are traced.
    ScenePayload payload = (ScenePayload)0;
    SurfaceHit hit;
    uint status = LoadVisibilitySurface(scene, launch, queries, hit);
    if (status == SCENE_QUERY_SURFACE)
        SceneShaderMain(scene, hit, queries, payload);
    else if (status == SCENE_QUERY_MISS)
        SceneShaderMain(scene, ShaderMain(launch), queries, payload);
    return payload.Radiance;
}
