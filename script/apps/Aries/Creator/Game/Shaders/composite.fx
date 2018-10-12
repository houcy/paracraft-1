/**
Author: LiXizhi
Company: ParaEngine
Date: 2015.5.10
Desc: Deferred shading post processing: 4 passes as below
pass0 (lightmap + shadow + HDR + nighteye + sunspot + torch glow) + (TODO:ssao, underwater, specularity)
pass1 (reflection) + (TODO:sunspot in water)
pass2 (bloom textures) + (TODO:average luminance)
final (DepthOfView + Bloom + RainFog + Vignette + ToneMap)  + (TODO: motionBlur + luminanceToneMap)

References:
http://www.gamedev.net/topic/506573-reconstructing-position-from-depth-data/
http://www.crytek.com/cryengine/presentations/real-time-atmospheric-effects-in-games-revisited
SUES v10.1: Sonic Ether's unbelievable shader
CustomBuild:"$(DXSDK_DIR)/Utilities/bin/x86/fxc.exe" /Tfx_2_0 /Gfp /nologo /Fo %(RelativeDir)/%(Filename).fxo %(FullPath)
OUTPUT:%(RelativeDir)%(Filename).fxo
*/
/** whether to enable debug view. lt:bloom textures, lr:bloom sum, lb:original, rb:final. */
// #define SHOW_DEBUG_VIEW

#include "CommonFunction.fx"

float4x4 matView;
float4x4 matViewInverse;
float4x4 matProjection;
float4x4 mShadowMapTex;
float4x4 mShadowMapViewProj;
float2	viewportOffset;
float2	viewportScale;
// fov,near,far,aspect
float4 ProjectionParams : ProjectionParams;
float3   g_FogColor;

// x is shadow map size(such as 2048), y = 1/x
float2  ShadowMapSize;
// usually 40 meters
float	ShadowRadius; 

/** whether to desaturate and apply blue tint at dark night. */
#define NIGHT_EYE_EFFECT

// x>0 use sun shadow map, y>0 use water reflection, z>=1 bloom, z>=2 depth of view. 
float3 RenderOptions;


float2 screenParam;
float centerDepthSmooth = 15.f;
// between [0,1]
float rainStrength = 0.f;
float EyeBrightness = 0.5;
float ViewAspect;
float TanHalfFOV;
float cameraFarPlane;
float3 cameraPosition;
float3 sunDirection;
float3 SunColor;
float3 TorchLightColor;
float timeNoon = 1.0; // 1 is noon. 0 is night
float timeMidnight = 0.0; // 1 is midnight.
float DepthOfViewFactor = 0.15;	//aperture - bigger values for shallower depth of field
float FogStart = 100.0;
float FogEnd = 140.0;
float CloudThickness = 0.0;
float2 GaussianBlurOffset;

static const float bloom_threshold = 0.7;
// offset_x, offset_y, scale_factor
static const float3 offsets[16] = {
	float3(0.008, 0.0, 1.0), float3(0.006, 0.0, 1.2), float3(0.004, 0.0, 1.3), float3(0.002, 0.0, 1.5),
	float3(0.0, 0.008, 1.0), float3(0.0, 0.006, 1.2), float3(0.0, 0.004, 1.3), float3(0.0, 0.002, 1.5),
	-float3(0.008, 0.0, 1.0), -float3(0.006, 0.0, 1.2), -float3(0.004, 0.0, 1.3), -float3(0.002, 0.0, 1.5),
	-float3(0.0, 0.008, 1.0), -float3(0.0, 0.006, 1.2), -float3(0.0, 0.004, 1.3), -float3(0.0, 0.002, 1.5)
};

texture sourceTexture0: TEXTURE0;
sampler2D colorSampler:register(s0) = sampler_state
{
	Texture = <sourceTexture0>;
	MinFilter = Linear;
	MagFilter = Linear;
	AddressU = clamp;
	AddressV = clamp;
};

texture sourceTexture1: TEXTURE1;
sampler2D matInfoSampler:register(s1) = sampler_state
{
	Texture = <sourceTexture1>;
	MinFilter = Linear;
	MagFilter = Linear;
	AddressU = clamp;
	AddressV = clamp;
};

texture sourceTexture2 : TEXTURE2;
sampler2D ShadowMapSampler: register(s2) = sampler_state
{
	texture = <sourceTexture2>;
	MinFilter = Linear;
	MagFilter = Linear;
	MipFilter = None;
	AddressU = BORDER;
	AddressV = BORDER;
	BorderColor = 0x0;
};

texture sourceTexture3: TEXTURE3;
sampler2D depthSampler:register(s3) = sampler_state
{
	Texture = <sourceTexture3>;
	MinFilter = Linear;
	MagFilter = Linear;
	AddressU = clamp;
	AddressV = clamp;
};

texture sourceTexture4: TEXTURE4;
sampler2D normalSampler:register(s4) = sampler_state
{
	Texture = <sourceTexture4>;
	MinFilter = Linear;
	MagFilter = Linear;
	AddressU = clamp;
	AddressV = clamp;
};
texture sourceTexture5: TEXTURE5;
sampler2D compositeSampler:register(s5) = sampler_state
{
	Texture = <sourceTexture5>;
	MinFilter = Linear;
	MagFilter = Linear;
	AddressU = clamp;
	AddressV = clamp;
};
struct VSOutput
{
	float4 pos			: POSITION;         // Screen space position
	float2 texCoord		: TEXCOORD0;        // texture coordinates
	float3 CameraEye		: TEXCOORD2;      // texture coordinates
};

//All sky shading attributes
struct SkyStruct {
	float3 	albedo;				//Diffuse texture aka "color texture" of the sky
	float3 sunSpot;
	float sunProximity;
};

// Surface shading properties
struct SurfaceStruct
{
	int category_id;
	float3 	albedo;					// Diffuse texture "color texture" in linear color space (gamma decoded)
	float3 	normal;					// Screen-space surface normals
	float3	cameraSpacePos;
	float3	CameraEye;
	float2	texCoord;
	float 	depth;					// scene depth
	float 	NdotL; 					// dot(normal, lightVector). used for direct lighting calculation
	float 	shadow;
	SkyStruct sky;
	bool mask_sky;
	bool mask_water;
	bool mask_torch;
};

// Surface shading properties
struct SurfaceStruct2
{
	int category_id;
	float3 	color;					// Diffuse texture "color texture" in linear color space (gamma decoded)
	float	sunlightVisibility;
	float	torch_light_strength;
	float3 	normal;					// Screen-space surface normals
	float3	cameraSpacePos;
	float3	CameraEye;
	float2	texCoord;
	float 	depth;					// scene depth
	float 	NdotL; 					// dot(normal, lightVector). used for direct lighting calculation
	float 	shadow;
	float	specularity;
	bool mask_sky;
	bool mask_water;
	bool mask_metal;
};

// Lightmaps directly from C++ engine
struct RawLightmapStruct
{
	float torch;				//Light emitted from torches and other emissive blocks
	float sky;					//Light coming from the sky
};

//Lighting information to light the scene. These are untextured colored lightmaps to be multiplied with albedo to get the final lit and textured image.
struct LightmapStruct
{
	float3 sunlight;				//Direct light from the sun
	float3 skylight;				//Ambient light from the sky
	float3 bouncedSunlight;		//Fake bounced light, coming from opposite of sun direction and adding to ambient light
	float3 scatteredSunlight;		//Fake scattered sunlight, coming from same direction as sun and adding to ambient light
	float3 torchlight;			//Light emitted from torches and other emissive blocks
	float3 nolight;				//Base ambient light added to everything. For lighting caves so that the player can barely see even when no lights are present
	float3 sky;					//Color and brightness of the sky itself
};

/* the final composition step to tonemap to monitor resolution.
*/
struct VSOutputFinal
{
	float4 pos			: POSITION;         // Screen space position
	float2 texCoord		: TEXCOORD0;        // texture coordinates
};

// Result of shading calculation variables
struct ShadingStruct
{
	float   direct;
	float 	bounced; 			//Fake bounced sunlight
	float 	skylight; 			//Light coming from sky
	float 	scattered; 			//Fake scattered sunlight
	float 	sunlightVisibility; //Shadows
};

//Final textured and lit images sorted by what is illuminating them.
struct FinalStruct {
	float3 sunlight;				//Direct light from the sun
	float3 skylight;				//Ambient light from the sky
	float3 torchlight;			//Light emitted from torches and other emissive blocks
	float3 nolight;				//Base ambient light added to everything. For lighting caves so that the player can barely see even when no lights are present
	float3 sky;					//Color and brightness of the sky itself
	float3 glow_torch;
};

struct PSOut
{
	// HDR color
	float4 Color	: COLOR0;
	// 32bits additional information. 
	half4 Color2	: COLOR1;
};

VSOutput CompositeQuadVS(float3 iPosition:POSITION,
	float2 texCoord : TEXCOORD0)
{
	VSOutput o;
	o.pos = float4(iPosition, 1);
	o.texCoord = texCoord;
	// for reconstructing world position from depth value
	float YF = TanHalfFOV;
	float XF = YF * ViewAspect;
	o.CameraEye = float3(o.pos.x*XF,o.pos.y*YF, 1);

	return o;
}

//Function that retrieves the diffuse texture and convert it into linear space.
float3  GetAlbedoLinear(float2 texCoord)
{
	// decode gama correction, so that we work in original linear space
	return pow(tex2D(colorSampler, texCoord).rgb, 2.2f);
}

//Desaturates any color input at night, simulating the rods in the human eye
// @param amount: How much will the new desaturated and tinted image be mixed with the original image
void DoNightEye(inout float3 color, float amount)
{
	float3 rodColor = float3(0.2, 0.5, 1.0); 	//Cyan color that humans percieve when viewing extremely low light levels via rod cells in the eye
	float colorDesat = dot(color, float3(1, 1, 1)); 	//Desaturated color
	color = lerp(color, rodColor*colorDesat, amount);
}

float2 convertCameraSpaceToScreenSpace(float3 cameraSpace)
{
	float4 clipSpace = mul(float4(cameraSpace, 1.0), matProjection);
	float2 NDCSpace = clipSpace.xy / clipSpace.w;
	float2 ScreenPos = 0.5 * NDCSpace + 0.5;
	return float2(ScreenPos.x, 1 - ScreenPos.y) * viewportScale + viewportOffset;
}


// compute water reflection by sampling along the reflected eye ray until a pixel is found. 
float4 	ComputeRayTraceReflection(float3 cameraSpacePosition, float3 cameraSpaceNormal)
{
	float initialStepAmount = 1;
	//float stepRefinementAmount = 0.1;
	//int maxRefinements = 0;

	float3 cameraSpaceViewDir = normalize(cameraSpacePosition);
	float3 cameraSpaceVector = normalize(reflect(cameraSpaceViewDir, cameraSpaceNormal)) * initialStepAmount;
	float3 oldPosition = cameraSpacePosition;
	float3 cameraSpaceVectorPosition = oldPosition + cameraSpaceVector;
	float2 currentPosition = convertCameraSpaceToScreenSpace(cameraSpaceVectorPosition);
	float4 color = float4(0, 0, 0, 0);
	float2 finalSamplePos = float2(0, 0);
	float ray_length = initialStepAmount;
	int numSteps = 0;
	int max_step = 12; // cameraFarPlane/initialStepAmount; 4 * (1.5^10) = 230
	while (numSteps < max_step &&
		(currentPosition.x > 0 && currentPosition.x < 1 &&
			currentPosition.y > 0 && currentPosition.y < 1))
	{
		float2 samplePos = currentPosition.xy;
		float sampleDepth = tex2Dlod(depthSampler, float4(samplePos, 0, 0)).r;

		float currentDepth = cameraSpaceVectorPosition.z;
		float diff = currentDepth - sampleDepth;

		if (diff >= 0 && sampleDepth > 0 && diff <= ray_length)
		{
			// found it, exit the loop
			finalSamplePos.xy = samplePos;
			numSteps = max_step;
		}
		else
		{
			ray_length *= 1.5;
			cameraSpaceVector *= 1.5;	//Each step gets bigger
			cameraSpaceVectorPosition += cameraSpaceVector;

			currentPosition = convertCameraSpaceToScreenSpace(cameraSpaceVectorPosition);
		}
		numSteps++;
	}

	if (finalSamplePos.x != 0 && finalSamplePos.y != 0)
	{
		// compute point color
		float2 texCoord = finalSamplePos.xy;
		color.rgb = GetAlbedoLinear(texCoord);
		color.a = clamp(1 - pow(distance(float2(0.5, 0.5), finalSamplePos.xy)*2.0, 2.0), 0.0, 1.0);
	}
	return color;
}

float CalculateSkylight(in SurfaceStruct surface)
{
	if (surface.category_id == 31)
	{
		// grass 
		return 1.0f;
	}
	else
	{
		const float3 upVector = float3(0, 1.0, 0);
		float skylight = dot(surface.normal, upVector);
		skylight = skylight * 0.4f + 0.6f;
		return skylight;
	}
}

//Calculates direct sunlight without visibility check. mainly depends on surface normal. 
float 	CalculateDirectLighting(in SurfaceStruct surface)
{
	if (surface.category_id == 31)
	{
		// grass 
		return 1.0f;
	}
	else if (surface.category_id == 18)
	{
		// leaves
		// if(NdotL > -0.01)
		// 	return max(0, NdotL);
		// else
		// 	return abs(NdotL) * 0.25;
		return 1.0f;
	}
	else
	{
		// default sun light 
		return max(0, surface.NdotL*0.99 + 0.01);
	}
}

// @return [0,1]: 1 is no shadow(fully visible), 0 is completely in shadow(dark, unvisible)
float 	CalculateSunlightVisibility(inout SurfaceStruct surface, in ShadingStruct shading)
{
	if (RenderOptions.x < 0.99f || rainStrength >= 0.99f) {
		// no shadow when raining
		surface.shadow = 1.0; 
		return 1.0f;
	}
	
	// only apply global sun shadows when there is enough sun light on the material
	if (shading.direct > 0.0f)
	{
		// reconstruct world space vector
		float4 vWorldPosition = float4(surface.cameraSpacePos, 1);
		vWorldPosition = mul(vWorldPosition, matViewInverse);

		surface.shadow = calculateShadowFactor(ShadowMapSampler, vWorldPosition, surface.depth, mShadowMapTex, mShadowMapViewProj, ShadowMapSize.x, ShadowMapSize.y, ShadowRadius);
		return surface.shadow;
	}
	else
	{
		surface.shadow = 0.0;
		return 0.0f;
	}
}

// Function that retrieves the lightmap of light emitted by emissive blocks like torches
// Apply inverse square law and normalize for natural light falloff
// return value is also [0, 1] but applied inverse square law. 
// Note: the precomputed lightmap is fine. if you want to change lightmap of torch yourself, call 
// ParaTerrain.GetBlockAttributeObject():SetField("UseLinearTorchBrightness", shader_method >=3);
float GetLightmapTorch(float lightmap)
{
	lightmap = 1.0f - lightmap;
	lightmap = pow(lightmap, 2.0f);
	lightmap = 1.0f / pow((lightmap * 6 + 0.2f), 2.0f);
	lightmap -= 0.0260; // = 1.0f / pow((1 * 6 + 0.2f), 2.0f);
	lightmap = max(0.0f, lightmap);
	lightmap *= 0.04f;
	return lightmap;
}

//Function that retrieves the lightmap of light emitted by the sky. This is a raw value from 0 (fully dark) to 1 (fully lit) regardless of time of day
float 	GetLightmapSky(float skylight) {
	return pow(skylight, 4.3f);
}

//Function that retrieves the screen space surface normals. Used for lighting calculations
float4  GetNormal(float2 texCoord) {
	float4 norm = tex2D(normalSampler, texCoord);
	return float4(norm.rgb * 2.0 - 1.0, norm.w);
}

/* linear depth in camera space. [0, cameraFarPlane] */
float  GetDepth(float2 texCoord) {
	return tex2D(depthSampler, texCoord).x;
}

float GetSunlightVisibility(float2 coord)
{
	return tex2D(ShadowMapSampler, coord).g;
}

// @param vec2Seed: normally this is texture coordinate.
float noise(float offset, float2 vec2Seed)
{
	float2 coord = vec2Seed + offset.xx;
	float noise = clamp(frac(sin(dot(coord, float2(12.9898f, 78.233f))) * 43758.5453f), 0.0f, 1.0f)*2.0f - 1.0f;
	return noise;
}

//Calculates direct sunlight without visibility check
void CalculateNdotL(inout SurfaceStruct surface)
{
	surface.NdotL = dot(sunDirection, surface.normal);
}

//Mask
void 	CalculateMasks(inout SurfaceStruct surface)
{
	surface.mask_sky = surface.depth < 0.01;
	surface.mask_water = (surface.category_id == 8 || surface.category_id == 9);
	surface.mask_torch = (surface.category_id == 5);
}

//circular sun
// return 1 is sun, 0 is not sun. 
bool CalculateSunspot(inout SurfaceStruct surface)
{
	float3 npos = normalize(surface.CameraEye);
	float3 halfVector2 = normalize(-mul(sunDirection, (float3x3)matView).xyz + npos);
	float sunProximity = 1.0f - dot(halfVector2, npos);
	surface.sky.sunProximity = sunProximity;
	return (sunProximity > 0.96f);
}

void AddSunglow(inout SurfaceStruct surface)
{
	float sunglowFactor = pow(surface.sky.sunProximity, 4.4);
	surface.sky.albedo *= 1.0f + sunglowFactor * (7.0f);
}

// this is not fog, but a very low frequency scattering of fog color over the entire scene. 
void CalculateAtmosphericScattering(inout float3 color, in SurfaceStruct surface)
{
	float3 fogColor = g_FogColor.rgb;
	float fogFactor = pow(surface.depth / 1500.0f, 2.0f);
	// only paint on non-sky area
	fogFactor *= lerp(1.0f, 0.0f, float(surface.mask_sky));
	//add scattered low frequency light
	color += fogColor * fogFactor * 2.0f;
}

// apply fog effect from FogStart to cameraFarPlane
// NOT used: really bad effect. with depth of view, distance fog is not needed. 
void ApplyDistanceFog(inout float3 color, in SurfaceStruct surface)
{
	float3 fogColor = g_FogColor.rgb;
	float fogFactor = clamp((surface.depth - FogStart) / (cameraFarPlane - 16) * 6.0, 0.0, 1.0);
	// only paint on non-sky area
	fogFactor *= lerp(1.0f, 0.0f, float(surface.mask_sky));
	color = lerp(color, fogColor, fogFactor);
}

float3 CalculateViewPosFromDepth(float linearDepth,float3 cameraRay)
{
	float farClipDist = ProjectionParams.z;
	float3 viewspacePos = cameraRay * linearDepth * farClipDist;
	return viewspacePos.xyz;
}


// do basic surface color calculation here (without reflection)
PSOut CompositePS0(VSOutput input)
{
	//Initialize surface properties required for lighting calculation for any surface that is not part of the sky

	SurfaceStruct surface;
	float2 texCoord = input.texCoord;
	surface.texCoord = texCoord;
	surface.albedo = GetAlbedoLinear(texCoord);
	surface.sky.albedo = surface.albedo;
	surface.sky.sunSpot = float3(0,0,0);
	surface.sky.sunProximity = 0;
	surface.NdotL = 0;
	surface.shadow = 0;
	surface.mask_sky = false;
	surface.mask_water = false;
	surface.mask_torch = false;

	surface.albedo = pow(surface.albedo, 1.4f);
	surface.albedo = lerp(surface.albedo, dot(surface.albedo, float1(0.3333f).xxx), 0.035f);
	surface.normal = GetNormal(texCoord);
	surface.depth = GetDepth(texCoord);
	surface.CameraEye = input.CameraEye;
	surface.cameraSpacePos = CalculateViewPosFromDepth(surface.depth,input.CameraEye);

	// r:category id,  g: sun light value, b: torch light value
	float4 block_info = tex2D(matInfoSampler, texCoord);
	surface.category_id = (int)(block_info.r * 255.0 + 0.4);
	float sun_light_strength = block_info.g;
	float torch_light_strength = block_info.b;

	CalculateMasks(surface);

	//Remove the sky from surface albedo, because sky will be handled separately
	surface.albedo *= 1.0f - float(surface.mask_sky);
	//Initialize sky surface properties
	surface.sky.albedo = surface.sky.albedo * float(surface.mask_sky); //Gets the albedo texture for the sky
	surface.sky.sunSpot = SunColor * (float(CalculateSunspot(surface)) * float(surface.mask_sky));
	surface.sky.sunSpot *= 1.0f - rainStrength;
	surface.sky.sunSpot *= 1.0f - timeMidnight;
	surface.sky.sunSpot *= 100.0f;
	AddSunglow(surface);

	//Initialize original Lightmap values
	RawLightmapStruct rawLightmap;
	rawLightmap.torch = GetLightmapTorch(torch_light_strength);
	rawLightmap.sky = GetLightmapSky(sun_light_strength);

	//Calculate surface shading
	ShadingStruct shading;
	CalculateNdotL(surface);
	float directSunShading = CalculateDirectLighting(surface); //Calculate direct sunlight without visibility check (shadows)
	shading.direct = lerp(CloudThickness, 1.0, directSunShading);
	shading.sunlightVisibility = CalculateSunlightVisibility(surface, shading);
	shading.direct *= lerp(CloudThickness, 1.0, shading.sunlightVisibility);
	shading.direct *= 1.0f - rainStrength;
	shading.direct *= 1.0f - CloudThickness;
	shading.direct *= pow(rawLightmap.sky, 0.1f);
	shading.skylight = CalculateSkylight(surface);

	//Colorize surface shading and store in lightmaps
	LightmapStruct lightmap;
	lightmap.sunlight = SunColor.rgb * shading.direct;
	lightmap.skylight = rawLightmap.sky;
	lightmap.skylight *= shading.skylight;
	//give some ambient sunlight plus some base ambient at night. 
	lightmap.skylight *= (SunColor.rgb*(1.0f - CloudThickness)*2.0 + lerp(1.0, 0.1f, pow(timeMidnight, 0.6)));
	// lightmap.nolight = float3(0.05f, 0.05f, 0.05f);
	// also give torch light some fake shading to make custom model look more dimentional at night. 
	float fakeTorchShading = 1.0;
	if (surface.category_id == 255) {
		fakeTorchShading = (directSunShading * 0.6 + 0.4);
		lightmap.skylight *= fakeTorchShading;
	}
	lightmap.torchlight = (rawLightmap.torch * fakeTorchShading) * TorchLightColor;

	//Apply lightmaps to albedo and generate final shaded surface
	FinalStruct final;
	//final.nolight = surface.albedo * lightmap.nolight;
	final.sunlight = surface.albedo * lightmap.sunlight;
	final.skylight = surface.albedo * lightmap.skylight;
	final.torchlight = surface.albedo * lightmap.torchlight;
	final.glow_torch = surface.albedo * (float(surface.mask_torch) * TorchLightColor);
	// final.glow_torch = pow(final.glow_torch, 2.0);

#ifdef NIGHT_EYE_EFFECT
	float nightEyeAmount = timeMidnight*0.8;
	DoNightEye(final.sunlight, nightEyeAmount);
	DoNightEye(final.skylight, nightEyeAmount);
	DoNightEye(surface.sky.albedo, nightEyeAmount);
	// DoNightEye(final.nolight, 0.8);
#endif

	float3 finalComposite;
	finalComposite = final.sunlight	    * 1.0f					//Add direct sunlight
		+ final.skylight     * 0.05f					//Add ambient skylight
														// + final.nolight	    * 0.03f					//Add base ambient light
		+ final.torchlight   * 2.0					//Add light coming from emissive blocks
		+ final.glow_torch   * 3.0f					// add torch, lamp, lava glow
		;
	//Apply sky to final composite
	// surface.sky.albedo *= lerp(1.0f, 3.0f, timeNoon);
	surface.sky.albedo += surface.sky.sunSpot;
	finalComposite += surface.sky.albedo;

	CalculateAtmosphericScattering(finalComposite, surface);
	// ApplyDistanceFog(finalComposite, surface);

	// Convert final image back into gamma 0.45 space
	finalComposite.rgb = pow(finalComposite.rgb, (1.0f / 2.2f));

	// Scale image down for HDR, only required for integer16, not floating16. 
	// finalComposite.rgb *= 0.01f;

	PSOut o;
	o.Color = float4(finalComposite.rgb, 1.0);
	o.Color2 = float4(0, surface.shadow * pow(rawLightmap.sky, 0.2f), rawLightmap.sky, 1.0);
	return o;
}

float4 ComputeFakeSkyReflection(inout SurfaceStruct2 surface)
{
	// TODO
	return float4(0, 0, 0, 1.0);
}

void CalculateSpecularReflections(inout SurfaceStruct2 surface)
{
	int category_id = surface.category_id;

	surface.mask_sky = surface.depth < 0.01;
	surface.mask_water = (category_id == 8 || category_id == 9);
	surface.mask_metal = (category_id == 50);

	if (surface.mask_water || surface.mask_metal)
	{
		// water is 1 (full), metal is has a week reflective color. 
		float specularity = lerp(1.0, surface.specularity, surface.mask_metal);
		float3 cameraSpaceNormal = mul(surface.normal, (float3x3)matView);
		float4 reflection = ComputeRayTraceReflection(surface.cameraSpacePos, cameraSpaceNormal);
		float4 fakeSkyReflection = ComputeFakeSkyReflection(surface);
		reflection.a = reflection.a * fakeSkyReflection.a * specularity;
		surface.color.xyz = lerp(surface.color.xyz, reflection.rgb, reflection.a);
	}
}


/** sunlight specularity based on sun and eye half vector, and the normal */
void CalculateSpecularHighlight(inout SurfaceStruct2 surface)
{
	if (!surface.mask_sky && !surface.mask_water)
	{
		// everything has some specular light, metal block has more
		// float roughness = lerp(1, 0.5, surface.mask_metal);
		// float gloss = pow(1.01f - roughness, 4.5f);
		float gloss = lerp(0, surface.specularity*0.05, surface.mask_metal);

		float3 cameraSpaceViewDir = -normalize(surface.cameraSpacePos);
		float3 cameraSpaceNormal = mul(surface.normal, (float3x3)matView);
		float3 halfVector = normalize(mul(sunDirection, (float3x3)matView).xyz + cameraSpaceViewDir);
		float HdotN = saturate(dot(halfVector, cameraSpaceNormal));

		const float fresnelPower = 6.0;
		float fresnel = pow(saturate(1.0 - dot(cameraSpaceViewDir, cameraSpaceNormal)), fresnelPower) * 0.98 + 0.02;
		float spec = pow(HdotN, gloss * 5000 + 10.0);
		spec *= fresnel;
		spec *= gloss * 600 + 0.02; // 0.02 is base specular for all blocks.
		spec *= surface.sunlightVisibility;
		spec *= 1.0 - rainStrength;
		float3 specularHighlight = spec * SunColor;

		// For fake torch specular light, we will assume torch light and eye are on the same point, so half vector is actually viewDir.
		if (surface.mask_metal)
		{
			float spec = pow(saturate(dot(cameraSpaceViewDir, cameraSpaceNormal)), 60.0);
			specularHighlight += (TorchLightColor.rgb*pow(surface.torch_light_strength*spec, 3.0));
		}
		surface.color.xyz += specularHighlight;
	}
}

// do water reflection here
float4 CompositePS1(VSOutput input) :COLOR
{
	SurfaceStruct2 surface;
	float2 texCoord = input.texCoord;
	surface.texCoord = texCoord;
	surface.color = GetAlbedoLinear(texCoord);
	surface.sunlightVisibility = GetSunlightVisibility(texCoord);
	// get world space normal
	float4 normal_ = GetNormal(texCoord);
	surface.normal = normal_.xyz;
	surface.specularity = 1.0 - normal_.w;
	surface.depth = GetDepth(texCoord);
	surface.CameraEye = input.CameraEye;
	surface.cameraSpacePos = CalculateViewPosFromDepth(surface.depth,input.CameraEye);
	// r:category id,  g: sun light value, b: torch light value
	float4 block_info = tex2D(matInfoSampler, texCoord);
	surface.category_id = (int)(block_info.r * 255.0 + 0.4);
	// float sun_light_strength = block_info.g;
	surface.torch_light_strength = block_info.b;

	CalculateSpecularReflections(surface);
	CalculateSpecularHighlight(surface);

	return float4(surface.color.rgb, 1.0);
}

// calculate bloom at given level of detail and write it to a given offset position
float3 CalculateBloom(float2 texcoord)
{
	float3 color = tex2D(colorSampler, texcoord).rgb;
	float brightness = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    if(brightness > 2.5)
        return color;
	return float3(0,0,0);
}

// calculate bloom texture (several bloom texture resolutions are calculated in one pass in different locations of the texture) 
float4 CompositePS2(VSOutput input) :COLOR
{
	float2 texCoord = input.texCoord;
	float3 bloom = CalculateBloom(texCoord);
	return float4(bloom.rgb, 1.0f);
}

float4 CompositGaussianblurPS(VSOutput input) :COLOR
{
	float2 uv = input.texCoord;
	float2 texelSize = 1.0 / screenParam;
	float3 color = float3(0,0,0);
	float2 offset = GaussianBlurOffset*texelSize;
	color += 0.0205 * tex2D(colorSampler, uv - offset*3).rgb;
	color += 0.0855 * tex2D(colorSampler, uv - offset*2).rgb;
	color += 0.232  * tex2D(colorSampler, uv - offset*1).rgb;
	color += 0.324  * tex2D(colorSampler, uv).rgb;
	color += 0.232  * tex2D(colorSampler, uv + offset*1).rgb;
	color += 0.0855 * tex2D(colorSampler, uv + offset*2).rgb;
	color += 0.0205 * tex2D(colorSampler, uv + offset*3).rgb;
	return float4(color, 1.0);
}

// down size to 1/4 of original size. Calculate average color.
float4 GlowDownsizePS(VSOutputFinal input) :COLOR
{
	float2 texcoord = input.texCoord;
	float2 texStep = float2(1.0, 1.0) / screenParam;
	float3 bloom = float3(0.0, 0.0, 0.0);
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 4; j++) {
			float2 coord = float2(i, j) * texStep;
			float2 finalCoord = (texcoord.xy + coord.xy);
			bloom += tex2D(colorSampler, finalCoord).rgb;
		}
	}
	return float4(bloom.rgb / 16.0, 1.0f);
}




VSOutputFinal FinalQuadVS(float3 iPosition:POSITION,
	float2 texCoord : TEXCOORD0)
{
	VSOutputFinal o;
	o.pos = float4(iPosition, 1);
	o.texCoord = texCoord + 0.5 / screenParam;
	return o;
}

// get and convert to linear color space (decode gamma)
float3 	GetColorTexture(float2 coord)
{
	return tex2D(compositeSampler, coord).rgb;
}

// value based on SEUS v10.0
float3 DepthOfField(float2 pos)
{
	float cursorDepth = centerDepthSmooth;
	if (cursorDepth == 0.0) {
		// just in case it is first person view. 
		cursorDepth = tex2D(depthSampler, float2(0.5, 0.5)).x;
	}

	const float blurclamp = 0.014;  // max blur amount

	float2 aspectcorrect = float2(1.0, ViewAspect) * 1.5;

	float depth = tex2D(depthSampler, pos).x;
	// depth += float(isHand) * 0.36f;

	float factor = (depth - cursorDepth) / cameraFarPlane;

	float2 dofblur = clamp(factor * DepthOfViewFactor, -blurclamp, blurclamp).xx;

	float3 col = float3(0.0, 0.0, 0.0);
	col += GetColorTexture(pos);

	col += GetColorTexture(pos + (float2(0.0, 0.4)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(0.15, 0.37)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(0.29, 0.29)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(-0.37, 0.15)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(0.4, 0.0)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(0.37, -0.15)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(0.29, -0.29)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(-0.15, -0.37)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(0.0, -0.4)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(-0.15, 0.37)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(-0.29, 0.29)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(0.37, 0.15)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(-0.4, 0.0)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(-0.37, -0.15)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(-0.29, -0.29)*aspectcorrect) * dofblur);
	col += GetColorTexture(pos + (float2(0.15, -0.37)*aspectcorrect) * dofblur);

	col += GetColorTexture(pos + (float2(0.15, 0.37)*aspectcorrect) * dofblur*0.9);
	col += GetColorTexture(pos + (float2(-0.37, 0.15)*aspectcorrect) * dofblur*0.9);
	col += GetColorTexture(pos + (float2(0.37, -0.15)*aspectcorrect) * dofblur*0.9);
	col += GetColorTexture(pos + (float2(-0.15, -0.37)*aspectcorrect) * dofblur*0.9);
	col += GetColorTexture(pos + (float2(-0.15, 0.37)*aspectcorrect) * dofblur*0.9);
	col += GetColorTexture(pos + (float2(0.37, 0.15)*aspectcorrect) * dofblur*0.9);
	col += GetColorTexture(pos + (float2(-0.37, -0.15)*aspectcorrect) * dofblur*0.9);
	col += GetColorTexture(pos + (float2(0.15, -0.37)*aspectcorrect) * dofblur*0.9);

	col += GetColorTexture(pos + (float2(0.29, 0.29)*aspectcorrect) * dofblur*0.7);
	col += GetColorTexture(pos + (float2(0.4, 0.0)*aspectcorrect) * dofblur*0.7);
	col += GetColorTexture(pos + (float2(0.29, -0.29)*aspectcorrect) * dofblur*0.7);
	col += GetColorTexture(pos + (float2(0.0, -0.4)*aspectcorrect) * dofblur*0.7);
	col += GetColorTexture(pos + (float2(-0.29, 0.29)*aspectcorrect) * dofblur*0.7);
	col += GetColorTexture(pos + (float2(-0.4, 0.0)*aspectcorrect) * dofblur*0.7);
	col += GetColorTexture(pos + (float2(-0.29, -0.29)*aspectcorrect) * dofblur*0.7);
	col += GetColorTexture(pos + (float2(0.0, 0.4)*aspectcorrect) * dofblur*0.7);

	col += GetColorTexture(pos + (float2(0.29, 0.29)*aspectcorrect) * dofblur*0.4);
	col += GetColorTexture(pos + (float2(0.4, 0.0)*aspectcorrect) * dofblur*0.4);
	col += GetColorTexture(pos + (float2(0.29, -0.29)*aspectcorrect) * dofblur*0.4);
	col += GetColorTexture(pos + (float2(0.0, -0.4)*aspectcorrect) * dofblur*0.4);
	col += GetColorTexture(pos + (float2(-0.29, 0.29)*aspectcorrect) * dofblur*0.4);
	col += GetColorTexture(pos + (float2(-0.4, 0.0)*aspectcorrect) * dofblur*0.4);
	col += GetColorTexture(pos + (float2(-0.29, -0.29)*aspectcorrect) * dofblur*0.4);
	col += GetColorTexture(pos + (float2(0.0, 0.4)*aspectcorrect) * dofblur*0.4);

	float3 color = col / 41;
	return color;
}


float3 TonemapReinhard_Good(float3 color)
{
	const float averageLuminance = 0.00003f;
	const float contrast = 0.9f;
	float3 value = pow(color.rgb, contrast);
	value = value / (value + EyeBrightness.xxx);
	color.rgb = value;
	return color;
}

void Vignette(inout float3 color, float2 pos)
{
	float dist = distance(pos, float2(0.5, 0.5)) * 2.0f / 1.5142;
	dist = pow(dist, 1.1f);
	color.rgb *= 1.0 - dist;
}

float4 FinalPS(VSOutput input) :COLOR
{
	float2 texCoord = input.texCoord;
	float3 color;
	if (RenderOptions.z >= 2)
		color = DepthOfField(texCoord);
	else
		color = GetColorTexture(texCoord);


 	float3 bloom =	tex2D(colorSampler,texCoord);
	color +=bloom;

	// apply user defined fog
	//float3 viewspacePos = CalculateViewPosFromDepth(GetDepth(texCoord),input.CameraEye);
	//float eyeDist = length(viewspacePos);
	//if (FogStart < FogEnd)
	//	color.xyz = lerp(color.xyz, pow(g_FogColor.xyz, 2.2f), 1.0 - clamp((FogEnd - eyeDist) / (FogEnd - FogStart), 0.0, 1.0));

	// vignette effect: darken edges
	Vignette(color, texCoord);

	color = TonemapReinhard_Good(color);
	//Put color back into gamma space for correct display
	color.rgb = pow(color.rgb, (1.0f / 2.2f));

	return float4(color, 1.0f);
}

float4 CompositeFXAA(VSOutput input) :COLOR
{
	return FxaaPixelShader(
	input.texCoord,							// FxaaFloat2 pos,
		FxaaFloat4(0.0f, 0.0f, 0.0f, 0.0f),		// FxaaFloat4 fxaaConsolePosPos,
		colorSampler,							// FxaaTex tex,
		colorSampler,							// FxaaTex fxaaConsole360TexExpBiasNegOne,
		colorSampler,							// FxaaTex fxaaConsole360TexExpBiasNegTwo,
		1.0 / screenParam,							// FxaaFloat2 fxaaQualityRcpFrame,
		FxaaFloat4(0.0f, 0.0f, 0.0f, 0.0f),		// FxaaFloat4 fxaaConsoleRcpFrameOpt,
		FxaaFloat4(0.0f, 0.0f, 0.0f, 0.0f),		// FxaaFloat4 fxaaConsoleRcpFrameOpt2,
		FxaaFloat4(0.0f, 0.0f, 0.0f, 0.0f),		// FxaaFloat4 fxaaConsole360RcpFrameOpt2,
		0.75f,									// FxaaFloat fxaaQualitySubpix,
		0.166f,									// FxaaFloat fxaaQualityEdgeThreshold,
		0.0833f,								// FxaaFloat fxaaQualityEdgeThresholdMin,
		0.0f,									// FxaaFloat fxaaConsoleEdgeSharpness,
		0.0f,									// FxaaFloat fxaaConsoleEdgeThreshold,
		0.0f,									// FxaaFloat fxaaConsoleEdgeThresholdMin,
		FxaaFloat4(0.0f, 0.0f, 0.0f, 0.0f)		// FxaaFloat fxaaConsole360ConstDir,
		);
}

technique Default_Normal
{
	// -- composite 0: calculate real color to HDR
	pass P0
	{
		cullmode = none;
		ZEnable = false;
		ZWriteEnable = false;
		FogEnable = False;
		VertexShader = compile vs_3_0 CompositeQuadVS();
		PixelShader = compile ps_3_0 CompositePS0();
	}
	// -- composite 1: do surface reflection
	pass P1
	{
		cullmode = none;
		ZEnable = false;
		ZWriteEnable = false;
		FogEnable = False;
		VertexShader = compile vs_3_0 CompositeQuadVS();
		PixelShader = compile ps_3_0 CompositePS1();
	}
	// -- composite 2: calculate bloom
	pass P2
	{
		cullmode = none;
		ZEnable = false;
		ZWriteEnable = false;
		FogEnable = False;
		VertexShader = compile vs_3_0 CompositeQuadVS();
		PixelShader = compile ps_3_0 CompositePS2();
	}
	// -- composite 3: final render back to render target. 
	pass P3
	{
		cullmode = none;
		ZEnable = false;
		ZWriteEnable = false;
		FogEnable = False;
		VertexShader = compile vs_3_0 CompositeQuadVS();
		PixelShader = compile ps_3_0 FinalPS();
	}
	// -- composite 2(pre): downsize and prepare glow texture. 1/4 of original size (unused)
	pass P4
	{
		cullmode = none;
		ZEnable = false;
		ZWriteEnable = false;
		FogEnable = False;
		VertexShader = compile vs_3_0 FinalQuadVS();
		PixelShader = compile ps_3_0 GlowDownsizePS();
	}
	// FXAA
	pass P5
	{		
		cullmode = none;
		ZEnable = false;
		ZWriteEnable = false;
		FogEnable = False;
		AlphaBlendEnable = false;
		VertexShader = compile vs_3_0 CompositeQuadVS();
		PixelShader = compile ps_3_0 CompositeFXAA();
	}

	// Gaussianblur
	pass P6
	{		
		cullmode = none;
		ZEnable = false;
		ZWriteEnable = false;
		FogEnable = False;
		AlphaBlendEnable = false;
		VertexShader = compile vs_3_0 CompositeQuadVS();
		PixelShader = compile ps_3_0 CompositGaussianblurPS();
	}
}
