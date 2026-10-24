void ShadeClosest(SceneContext scene,
                  SurfaceHit hit,
                  inout RayQueryContext inoutQueries,
                  inout ScenePayload inoutPayload)
{
    // The secondary ray terminates here: only authored surface emission contributes.
    // inoutPayload.Radiance = EvaluateEmission(scene, hit, -hit.IncomingRay.DirectionWorld);
    
    const MaterialSample material = EvaluateMaterial(scene, hit);
    inoutPayload.Radiance = material.BaseColor;
}
