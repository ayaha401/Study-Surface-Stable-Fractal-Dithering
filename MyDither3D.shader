Shader "Unlit/MyDither3D"
{
    Properties
    {
        _MainTex ("Albedo", 2D) = "white" {}

        [Header(Dither Settings)]
        _DitherTex ("Dither 3D Texture", 3D) = "" {}
        _DitherRampTex ("Dither Ramp Texture", 2D) = "white" {}
        _Scale ("Dot Scale", Range(2, 10)) = 5.0 // ディザ模様の丸の大きさ
        _SizeVariability ("Dot Size Variability", Range(0, 1)) = 0 // ディザ模様の丸の大きさの調整
        _Contrast ("Dot Contrast", Range(0, 2)) = 1 // MainTexの色との合成割合調整
        _StretchSmoothness ("Stretch Smoothness", Range(0, 2)) = 1 // モアレを防げる気がする
    }
    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "RenderPipeline" = "UniversalPipeline"
        }
        LOD 100

        Pass
        {
            Tags
            {
                "LightMode" = "UniversalForward"
            }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Assets/Shader/Utility/ColorFunction.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                float4 screenPos : TEXCOORD1;
            };

            sampler2D _MainTex;
            sampler3D _DitherTex;
            sampler2D _DitherRampTex;

            CBUFFER_START(UnityPerMaterial)
            float4 _MainTex_ST;
            float4 _DitherTex_TexelSize;
            float _Scale;
            float _SizeVariability;
            float _Contrast;
            float _StretchSmoothness;
            CBUFFER_END

            half4 MyGetDither3D(float2 uv_DitherTex, float4 screenPos, float2 dx, float2 dy, half brightness)
            {
                float xResolution = _DitherTex_TexelSize.z; // widthを取得(heightも同じだとする)
                float inverseXResolution = _DitherTex_TexelSize.x; // 1/widthされた値
                
                // 3DテクスチャのZの解像度を計算する
                float dotsPerSide = xResolution / 16.0; // 16で割るのは8x8のディザだから1つ16pxのはずだから？
                float dotsTotal = pow(dotsPerSide, 2); // 正方形の面積を求めるのと同じロジック(多分)
                float inverseZResolution = 1.0 / dotsTotal;

                // 明るさを計算(いい感じに補正していてわからん)
                // float2 lookup = float2((0.5 * inverseXResolution + (1 - inverseXResolution) * brightness), 0.5);
                // half brightnessCurve = tex2D(_DitherRampTex, lookup).r;
                // 最小限で構成するならこれでもよい気がする
                half brightnessCurve = tex2D(_DitherRampTex, brightness).r;

                // fwidth(uv_DitherTex)が簡単な方法だが、これだとアーティファクトが出るので他の方法で精度よく作る
                // 特異値分解を使用する
                float2x2 matr = { dx, dy }; // UV座標の微分（変化率） を表す。
                float4 vectorized = float4(dx, dy); // dx と dy を float4 に変換しているだけ。これは dot(vectorized, vectorized) を計算するための準備。
                float Q = dot(vectorized, vectorized); // 各要素の2乗和を求める。これは、すべての変化率の総和 に近い値。
                float R = determinant(matr); //ad-bc R=dx.x×dy.y−dx.y×dy.x
                float discriminantSqr = max(0, Q*Q-4*R*R); // 解の公式のルートの中 maxはsqrtの中がマイナスになるのを防ぐ
                float discriminant = sqrt(discriminantSqr); // 解の公式のルート計算
                
                // ここでの「freq」は、画面上の UV 座標の変化率を意味します。
                // 解の公式の+-の分の解をfloat2に入れつつ、解の公式の解にsqrtをする
                float2 freq = sqrt(float2(Q + discriminant, Q - discriminant) / 2);

                // ドット間隔はmin値を使用する
                float spacing = freq.y;

                // 指定された入力スケール（2 の累乗）で間隔を拡大縮小します。
                float scaleExp = exp2(_Scale);
                spacing *= scaleExp;
                spacing *= dotsPerSide * 0.125; // なんでするのかわからん

                // 明るさによってドットサイズを変更するための調整
                // _SizeVariabilityが0で間隔を明るさで割る
                // _SizeVariabilityが1の時は間隔をそのままにする
                // 0.001は中が0になるのを防止する
                float brightnessSpacingMultiplier = pow(brightnessCurve * 2 + 0.001, -(1 - _SizeVariability));
                spacing *= brightnessSpacingMultiplier;

                // ドット間隔に対応するフラクタルレベルを決める
                float spacingLog = log2(spacing);
                int patternScaleLevel = floor(spacingLog); // Fractal level.
                float f = spacingLog - patternScaleLevel; // Fractional part.

                // フラクタルレベルのUV座標を取得
                float2 uv = uv_DitherTex / exp2(patternScaleLevel);

                // 3DテクスチャのZに沿ったレイヤーを取得するために作成
                float subLayer = lerp(0.25 * dotsTotal, dotsTotal, 1 - f);
                subLayer = (subLayer - 0.5) * inverseZResolution; // 0 ～ 1 の範囲に正規化して扱う

                // 3D テクスチャをサンプリング
                half pattern = tex3D(_DitherTex, float3(uv, subLayer)).r;

                // SDFの円が入っているから乗算して色をシャープにする(だと思う)
                float contrast = _Contrast * scaleExp * brightnessSpacingMultiplier * 0.1;
                contrast *= pow(freq.y / freq.x, _StretchSmoothness);

                // わからん、いい感じの明るさの値
                half baseVal = lerp(0.5, brightness, saturate(1.05 / (1 + contrast)));

                half threshold = 1 - brightnessCurve;

                // ソースコードのbw変数名が何を意図しているのか不明。Black White？
                half bw = saturate((pattern - threshold) * contrast + baseVal);

                return half4(bw, frac(uv.x), frac(uv.y), subLayer);
            }

            half4 MyGetDither3DColor(float2 uv_DitherTex, float4 screenPos, half4 color)
            {
                // UV座標の変化率を取得
                float2 dx = ddx(uv_DitherTex);
                float2 dy = ddy(uv_DitherTex);

                // Brightnessはモノクロに変換して代入
                half4 dither = MyGetDither3D(uv_DitherTex, screenPos, dx, dy, convertMonochrome(color.rgb));

                color.rgb = dither.x;

                return color;
            }

            Varyings vert(Attributes v)
            {
                Varyings o;
                o.positionHCS = TransformObjectToHClip(v.positionOS.xyz);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                o.screenPos = ComputeScreenPos(o.positionHCS);
                return o;
            }

            float4 frag(Varyings i) : SV_Target
            {
                float4 col = tex2D(_MainTex, i.uv);
                col.rgb = MyGetDither3DColor(i.uv, i.screenPos, col);
                return col;
            }
            ENDHLSL
        }
    }
}
