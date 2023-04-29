(* ::Package:: *)

(* ::Section:: *)
(*Package Header*)


BeginPackage["AntonAntonov`QuantileRegression`"];

QuantileRegressionFit::usage = "QuantileRegressionFit[data,funs,var,probs] finds the regression quantiles corresponding \
to the probabilities probs for a list of data as linear combinations of the functions funs of the variable var.";

QuantileRegression::usage = "QuantileRegression[data,ks_List,probs] finds the regression quantiles corresponding \
to the probabilities probs for a list of data as linear combinations of splines generated over the knots ks. \
With the signature QuantileRegression[data,n_Integer,probs] n equally spaced knots are generated. \
The order of the splines is specified with the option InterpolationOrder.";

QuantileEnvelope::usage = "QuantileEnvelope[data_?MatrixQ,probs:(_?NumberQ|{_?NumberQ..}),ndir_Integer] \
experimental implementation of quantile envelopes points finding.";

QuantileEnvelopeRegion::usage = "QuantileEnvelopeRegion[data_?MatrixQ,q_?NumberQ,ndir_Integer] \
experimental implementation of 2D or 3D quantile envelope region finding.";

NURBSBasis::usage = "NURBSBasis[data_?MatrixQ, n_]";

Begin["`Private`"];


(************************************************************)
(* QuantileRegressionFit                                    *)
(************************************************************)

QuantileRegressionFit::"nmat" = "The first argument is expected to be a matrix of numbers with two columns, \
a numeric vector, or a time series.";

QuantileRegressionFit::"fvlen" = "The second argument is expected to be list of functions to be fitted with at least one element.";

QuantileRegressionFit::"nvar" = "The third argument is expected to be a symbol or a list of symbols.";

QuantileRegressionFit::"nprobs" = "The fourth argument is expected to be a list of numbers representing probabilities.";

QuantileRegressionFit::"nmeth" = "The value of the method option is expected to be \
LinearProgramming, Minimize, NMinimize or a list with LinearProgramming, Minimize, or NMinimize as a first element.";

QuantileRegressionFit::"mmslow" = "With the method Minimize the computations can be very slow for large data sets.";

QuantileRegressionFit::"mnd" = "The methods Minimize and NMinimize do not work on more than one regressors (variables). Consider using the method LinearProgramming instead.";

QuantileRegressionFit::"nargs" = "Four arguments are expected.";

Clear[QuantileRegressionFit];

Options[QuantileRegressionFit] = {Method -> LinearProgramming};

QuantileRegressionFit[data_?VectorQ, funcs_, varSpec : (_?AtomQ | {_?AtomQ..}), probs_, opts : OptionsPattern[]] :=
    QuantileRegressionFit[ Transpose[{ Range[Length[data]], data}], funcs, varSpec, probs, opts];

QuantileRegressionFit[data : (_TimeSeries | _TemporalData), funcs_, varSpec : (_?AtomQ | {_?AtomQ..}), probs_, opts : OptionsPattern[]] :=
    QuantileRegressionFit[ QuantityMagnitude[data["Path"]], funcs, varSpec, probs, opts];

QuantileRegressionFit[data_, funcs_, varSpec : (_?AtomQ | {_?AtomQ..}), probsArg_, opts : OptionsPattern[]] :=
    Block[{mOptVal, vars, probs = Flatten @ List @ probsArg},

      vars = If[AtomQ[varSpec], {varSpec}, varSpec];

      (*This check should not be applied because the first function can be a constant.*)
      (*!Apply[And,Map[!FreeQ[#,var]&,funcs]],Message[QuantileRegressionFit::\"fvfree\"],*)
      Which[
        ! ( MatrixQ[data, NumericQ] && Dimensions[data][[2]] >= 2 ),
        Message[QuantileRegressionFit::"nmat"]; Return[{}],

        Length[funcs] < 1,
        Message[QuantileRegressionFit::"fvlen"]; Return[{}],

        Not @ Apply[And, TrueQ[Head[#] === Symbol]& /@ vars],
        Message[QuantileRegressionFit::"nvar"]; Return[{}],

        ! VectorQ[probs, NumericQ[#] && 0 <= # <= 1 &],
        Message[QuantileRegressionFit::"nprobs"]; Return[{}]
      ];

      mOptVal = OptionValue[QuantileRegressionFit, Method];

      Which[
        TrueQ[mOptVal === LinearProgramming],
        LPQuantileRegressionFit[data, funcs, vars, probs],

        ListQ[mOptVal] && TrueQ[mOptVal[[1]] === LinearProgramming],
        LPQuantileRegressionFit[data, funcs, vars, probs, Rest[mOptVal]],

        TrueQ[mOptVal === Minimize || mOptVal === NMinimize] && Length[vars] == 1,
        MinimizeQuantileRegressionFit[mOptVal, data, funcs, vars[[1]], probs],

        TrueQ[mOptVal === Minimize || mOptVal === NMinimize],
        Message[QuantileRegressionFit::"mnd"]; Return[{}],

        ListQ[mOptVal] && TrueQ[mOptVal[[1]] === Minimize || mOptVal[[1]] === NMinimize] && Length[vars] == 1,
        MinimizeQuantileRegressionFit[mOptVal[[1]], data, funcs, vars[[1]], probs, Rest[mOptVal]],

        ListQ[mOptVal] && TrueQ[mOptVal[[1]] === Minimize || mOptVal[[1]] === NMinimize],
        Message[QuantileRegressionFit::"mnd"]; Return[{}],

        True,
        Message[QuantileRegressionFit::"nmeth"]; Return[{}]
      ]
    ];

QuantileRegressionFit[___] :=
    Block[{},
      Message[QuantileRegressionFit::"nargs"];
      {}
    ];

Clear[LPQuantileRegressionFit];

LPQuantileRegressionFit[dataArg_?MatrixQ, funcs_, vars : {_Symbol..}, probs : {_?NumberQ ..}, opts : OptionsPattern[]] :=
    Block[{data = dataArg, yMedian = 0, yFactor = 1, yShift = 0, mat, n = Dimensions[dataArg][[1]], pfuncs, c, t, qrSolutions},
      If[Min[data[[All, -1]]] < 0,
        yMedian = Median[data[[All, -1]]];
        yFactor = InterquartileRange[data[[All, -1]]];
        data[[All, -1]] = Standardize[data[[All, -1]], Median, InterquartileRange];
        yShift = Abs[Min[data[[All, -1]]]];(*this is Min[dataArg[[All,2]]-Median[dataArg[[All,2]]*)
        data[[All, -1]] = data[[All, -1]] + yShift ;
      ];

      pfuncs =
          Map[
            Function[{fb},
              With[{f = fb /. Thread[vars -> Map[Slot, Range[Length[vars]]]]}, f &]
            ],
            funcs
          ];
      mat = Map[Function[{f}, f @@@ data[[All, 1 ;; -2]]], pfuncs];
      mat = Map[Flatten, Transpose[Join[mat, {IdentityMatrix[n], -IdentityMatrix[n]}]]];
      mat = N[SparseArray[mat]];

      qrSolutions =
          Table[
            c = Join[ConstantArray[0, Length[funcs]], ConstantArray[1, n] * q, ConstantArray[1, n] * (1 - q)];
            t = LinearProgramming[c, mat, Transpose[{data[[All, -1]], ConstantArray[0, n]}], opts];
            If[ !(VectorQ[t, NumberQ] && Length[t] > Length[funcs]), ConstantArray[0, Length[funcs]], t ]
            , {q, probs}];


      If[yMedian == 0 && yFactor == 1,
        Map[funcs . # &, qrSolutions[[All, 1 ;; Length[funcs]]]],
        (*ELSE*)
        Map[Expand[yFactor * ((funcs . #) - yShift) + yMedian] &, qrSolutions[[All, 1 ;; Length[funcs]]]]
      ]
    ];


Clear[MinimizeQuantileRegressionFit];

MinimizeQuantileRegressionFit[methodFunc_, data_?MatrixQ, funcs_, var_Symbol, probs : {_?NumberQ ..}, opts : OptionsPattern[]] :=
    Block[{minFunc, Tilted, QRModel, b, bvars, qrSolutions},

      If[Length[data] > 300,
        Message[QuantileRegressionFit::"mmslow"]
      ];

      bvars = Array[b, Length[funcs]];

      Tilted[t_?NumberQ, x_] := Piecewise[{{(t - 1) x, x < 0}, {t x, x >= 0}}] /; t <= 1;
      QRModel[x_] := Evaluate[(bvars . funcs) /. var -> x];

      qrSolutions =
          Table[
            minFunc = Total[(Tilted[q, #1[[2]] - QRModel[#1[[1]]]] &) /@ data];
            methodFunc[{minFunc}, bvars, opts]
            , {q, probs}];

      Map[funcs . # &, qrSolutions[[All, 2, All, 2]]]
    ];


(************************************************************)
(* NURBS basis                                              *)
(************************************************************)

Clear[NURBSBasis];

Options[NURBSBasis] = {SplineClosed -> False, "RelativeMargin" -> 0.05};

NURBSBasis[data_?MatrixQ, n_Integer, opts : OptionsPattern[]] :=
    NURBSBasis[data, Table[n, Length @ data[[1]]] ];

NURBSBasis[data_?MatrixQ, nsArg : { _Integer .. }, opts : OptionsPattern[]] :=
    Module[{ns = nsArg, dim = Dimensions[data][[2]],
      lsMinMaxes, relMargin, cpts0, inds, inds01, cpts, aBasis},

      (* Process options *)
      relMargin = OptionValue[NURBSBasis, "RelativeMargin"];

      (* Extend number of points per side spec *)
      Which[
        dim < Length[ns],
        ns = Take[ns, dim],

        dim > Length[ns],
        ns = Take[Flatten[Table[ns, dim]], dim]
      ];

      (* Min-max per column *)
      lsMinMaxes = MinMax /@ Transpose[data];

      (* The application of margins is needed to prevent instabilities of the basis value computations. *)
      lsMinMaxes =
          Map[ {
            #[[1]] - (#[[2]] - #[[1]]) * relMargin,
            #[[2]] + (#[[2]] - #[[1]]) * relMargin
          }&, lsMinMaxes];

      (* Make the basis *)
      cpts0 = Outer[{0} &, Sequence @@ Map[Table[i, {i, 0, 1, 1 / (# - 1)}] &, ns]];
      inds = Outer[List, Sequence @@ Map[Range, ns]];
      inds = Flatten[inds, dim - 1];

      inds01 = Transpose @ MapThread[ Rescale[#1, {1, #2}, #3]&, {Transpose @ inds, ns, lsMinMaxes}];

      aBasis =
          Association @ MapThread[
            #2 -> (
              cpts = cpts0;
              cpts = ReplacePart[cpts, #1 -> {1}];
              With[{f = BSplineFunction[cpts, Sequence @@ FilterRules[{opts}, Options[BSplineFunction]]]},
                Evaluate[f @@ Table[ Rescale[Slot[i], lsMinMaxes[[i]]], {i, Length[lsMinMaxes]}] ]&]
            )&,
            {inds, inds01}
          ];

      (* Result *)
      aBasis
    ];


(************************************************************)
(* QuantileRegression                                       *)
(************************************************************)

Clear[QuantileRegression];

SyntaxInformation[QuantileRegression] = { "ArgumentsPattern" -> { _., _, _, OptionsPattern[] } };

QuantileRegression::"nmat" = "The first argument is expected to be a matrix of numbers with two columns.";

QuantileRegression::"knord" = "The specified knots `1` and interpolation order `2` produce no B-Spline basis functions. \
The expression n - i - 2 should be non-negative, where n is the number of knots and i is the interpolation order.";

QuantileRegression::"zerob" = "The specified knots `1` and interpolation order `2` produced a list of zeroes instead of a list of B-Spline basis functions.";

QuantileRegression::"knspec" = "The knots specification (for using B-splines) has to be an integer or a list of numbers.";

QuantileRegression::"nprobs" = "The third argument is expected to be a list of numbers representing probabilities.";

QuantileRegression::"nmeth" = "The value of the method option is expected to be \
LinearProgramming, Minimize, NMinimize or a list with LinearProgramming, Minimize, or NMinimize as a first element.";

QuantileRegression::"norder" = "The value of the option InterpolationOrder is expected to be a non-negative integer.";

QuantileRegression::"nargs" = "Three arguments are expected.";

QuantileRegression::"mmslow" = "With the method Minimize the computations can be very slow for large data sets.";

Options[QuantileRegression] = {InterpolationOrder -> 3, Method -> LinearProgramming};

QuantileRegression[data_?VectorQ, knots_, probs_, opts : OptionsPattern[]] :=
    QuantileRegression[ Transpose[{ Range[Length[data]], data}], knots, probs, opts];

QuantileRegression[data : (_TimeSeries | _TemporalData), knots_, probs_, opts : OptionsPattern[]] :=
    QuantileRegression[ QuantityMagnitude[data["Path"]], knots, probs, opts];

QuantileRegression[data_, knots_, probsArg_, opts : OptionsPattern[]] :=
    Block[{mOptVal, intOrdOptVal, probs = Flatten @ List @ probsArg},

      Which[
        ! ( MatrixQ[data, NumericQ] && Dimensions[data][[2]] >= 2 ),
        Message[QuantileRegression::"nmat"]; Return[{}],

        !(IntegerQ[knots] && knots > 0 || VectorQ[knots, NumericQ]),
        Message[QuantileRegression::"knspec"]; Return[{}],

        ! VectorQ[probs, NumericQ[#] && 0 <= # <= 1 &],
        Message[QuantileRegression::"nprobs"]; Return[{}]
      ];

      mOptVal = OptionValue[QuantileRegression, Method];
      intOrdOptVal = OptionValue[QuantileRegression, InterpolationOrder];

      Which[
        !( IntegerQ[intOrdOptVal] && intOrdOptVal >= 0 ),
        Message[QuantileRegression::"norder"]; Return[{}],

        TrueQ[mOptVal === LinearProgramming],
        LPSplineQuantileRegression[data, knots, intOrdOptVal, probs],

        ListQ[mOptVal] && TrueQ[mOptVal[[1]] === LinearProgramming],
        LPSplineQuantileRegression[data, knots, intOrdOptVal, probs, Rest[mOptVal]],

        TrueQ[mOptVal === Minimize || mOptVal === NMinimize],
        MinimizeSplineQuantileRegression[mOptVal, data, knots, intOrdOptVal, probs],

        ListQ[mOptVal] && TrueQ[mOptVal[[1]] === Minimize || mOptVal[[1]] === NMinimize],
        MinimizeSplineQuantileRegression[mOptVal[[1]], data, knots, intOrdOptVal, probs, Rest[mOptVal]],

        True,
        Message[QuantileRegression::"nmeth"]; Return[{}]
      ]
    ];

QuantileRegression[___] :=
    Block[{},
      Message[QuantileRegression::"nargs"];
      {}
    ];

Clear[LPSplineQuantileRegression];

LPSplineQuantileRegression[data_?MatrixQ, npieces_Integer, order_Integer, probs : {_?NumberQ ..}, opts : OptionsPattern[]] :=
    LPSplineQuantileRegression[data, Rescale[Range[0, 1, 1 / npieces], {0, 1}, {Min[data[[All, 1]]], Max[data[[All, 1]]]}], order, probs, opts];

LPSplineQuantileRegression[dataArg_?MatrixQ, knotsArg : {_?NumberQ ..}, order_Integer, probs : {_?NumberQ ..}, opts : OptionsPattern[]] :=
    Block[{data = dataArg, knots = Sort[knotsArg], yMedian = 0, yFactor = 1, yShift = 0, n = Dimensions[dataArg][[1]], pfuncs, c, t, qrSolutions, mat},

      If[Min[data[[All, 2]]] < 0,
        yMedian = Median[data[[All, 2]]];
        yFactor = InterquartileRange[data[[All, 2]]];
        data[[All, 2]] = Standardize[data[[All, 2]], Median, InterquartileRange];
        yShift = Abs[Min[data[[All, 2]]]];
        data[[All, 2]] = data[[All, 2]] + yShift ;
      ];

      (* Enhance the knots list with additional clamped knots. *)
      knots = Join[Table[Min[knots], {order}], knots, Table[Max[knots], {order}]];

      If[Length[knots] - order - 2 < 0,
        Message[QuantileRegression::"knord", knots, order];
        Return[{}]
      ];

      (* B-spline basis expressions *)
      pfuncs = Table[PiecewiseExpand[BSplineBasis[{order, knots}, i, t]], {i, 0, Length[knots] - order - 2}];

      If[VectorQ[pfuncs, # == 0 &],
        Message[QuantileRegression::"zerob", knots, order];
        Return[{}]
      ];

      (* B-spline basis functions *)
      pfuncs = Function[{f}, With[{bf = f /. t -> #}, bf &]] /@ pfuncs;

      (* Create the conditions matrix *)
      mat = Table[Join[Through[pfuncs[data[[i, 1]]]]], {i, 1, n}];
      mat = MapThread[Join, {mat, IdentityMatrix[n], -IdentityMatrix[n]}];

      mat = SparseArray[mat];

      (* Find the regression quantiles *)
      qrSolutions =
          Table[
            c = Join[ConstantArray[0, Length[pfuncs]], ConstantArray[1, n] q, ConstantArray[1, n] (1 - q)];
            t = LinearProgramming[c, mat, Transpose[{data[[All, 2]], ConstantArray[0, n]}], DeleteCases[{opts}, InterpolationOrder -> _]];
            If[! (VectorQ[t, NumberQ] && Length[t] > Length[pfuncs]), ConstantArray[0, Length[pfuncs]], t]
            , {q, probs}];

      If[yMedian == 0 && yFactor == 1,
        Table[ With[{f = pfuncs[[All, 1]] . qrSolutions[[i, 1 ;; Length[pfuncs]]]}, f &], {i, 1, Length[probs]}],
        (*ELSE*)
        Map[Function[{ws}, With[{f = yFactor*((pfuncs[[All, 1]] . ws) - yShift) + yMedian}, f &]], qrSolutions[[All, 1 ;; Length[pfuncs]]]]
      ]
    ];

Clear[MinimizeSplineQuantileRegression];

MinimizeSplineQuantileRegression[methodFunc_, data_?MatrixQ, npieces_Integer, order_Integer, probs : {_?NumberQ ..}, opts : OptionsPattern[]] :=
    MinimizeSplineQuantileRegression[methodFunc, data, Rescale[Range[0, 1, 1 / npieces], {0, 1}, {Min[data[[All, 1]]], Max[data[[All, 1]]]}], order, probs, opts];

MinimizeSplineQuantileRegression[methodFunc_, dataArg_?MatrixQ, knotsArg : {_?NumberQ ..}, order_Integer, probs : {_?NumberQ ..}, opts : OptionsPattern[]] :=
    Block[{data = dataArg, knots = Sort[knotsArg], bvars, pfuncs, b, t, Tilted, QRModel, qrSolutions, minFunc},

      If[Length[data] > 300,
        Message[QuantileRegression::"mmslow"]
      ];

      (* Enhance the knots list with additional clamped knots. *)
      knots = Join[Table[Min[knots], {order}], knots, Table[Max[knots], {order}]];

      If[Length[knots] - order - 2 < 0,
        Message[QuantileRegression::"knord", knots, order];
        Return[{}]
      ];

      (* B-spline basis expressions *)
      pfuncs = Table[PiecewiseExpand[BSplineBasis[{order, knots}, i, t]], {i, 0, Length[knots] - order - 2}];

      If[VectorQ[pfuncs, # == 0 &],
        Message[QuantileRegression::"zerob", knots, order];
        Return[{}]
      ];

      (* B-spline basis functions *)
      pfuncs = Function[{f}, With[{bf = f /. t -> #}, bf &]] /@ pfuncs;

      (* Create the model *)
      Tilted[t_?NumberQ, x_] := Piecewise[{{(t - 1) x, x < 0}, {t x, x >= 0}}] /; t <= 1;
      bvars = Array[b, Length[pfuncs]];
      QRModel = With[{tf = bvars . pfuncs[[All, 1]]}, tf &];

      (* Find the regression quantiles *)
      qrSolutions =
          Table[
            minFunc = Total[(Tilted[q, #1[[2]] - QRModel[#1[[1]]]] &) /@ data];
            methodFunc[minFunc, bvars, opts]
            , {q, probs}];

      Table[ With[{f = pfuncs[[All, 1]] . (bvars /. qrSolutions[[i, 2]])}, f &], {i, 1, Length[probs]}]
    ] /; order > 0;


(**************************************************************)
(* QuantileEnvelope                                           *)
(**************************************************************)

QuantileEnvelope::qenargs = "Three arguments are expected, two column data matrix, probabilities, and a number of curve points.";
QuantileEnvelope::qemat = "The first argument is expected to be a numeric two column data matrix.";
QuantileEnvelope::qeqs = "The second argument is expected to be a number or a list of numbers between 0 and 1.";
QuantileEnvelope::qen = "The third argument is expected to be an integer greater than 2.";

Clear[QuantileEnvelope];

Options[QuantileEnvelope] =
    {"Tangents" -> True, "StandardizingShiftFunction" -> Mean, "StandardizingScaleFunction" -> InterquartileRange };

QuantileEnvelope[data_, probs_, n_, opts : OptionsPattern[]] :=
    Block[{},
      If[! MatrixQ[data, NumberQ],
        Message[QuantileEnvelope::qemat];
        Return[{}]
      ];
      If[! (TrueQ[ VectorQ[probs, NumberQ] && Apply[And, Map[0 <= # <= 1 &, probs]]] || TrueQ[NumberQ[probs] && (0 <= probs <= 1)]),
        Message[QuantileEnvelope::qeqs];
        Return[{}]
      ];
      If[! TrueQ[IntegerQ[n] && (n > 2)],
        Message[QuantileEnvelope::qen];
        Return[{}]
      ];
      QuantileEnvelopeSimple[data, probs, n, opts]
    ];

Clear[QuantileEnvelopeSimple];

Options[QuantileEnvelopeSimple] = Options[QuantileEnvelope];

QuantileEnvelopeSimple[data_?MatrixQ, q_?NumberQ, n_Integer, opts : OptionsPattern[]] := QuantileEnvelopeSimple[data, {q}, n, opts];

QuantileEnvelopeSimple[dataArg_?MatrixQ, probs : {_?NumberQ ..}, n_Integer, opts : OptionsPattern[]] :=
    Block[{data = dataArg, center, scale, rmat, rmats, qfuncs, x1, x2, y1, rqfuncs, intPoints, t,
      tangentsQ, sdShiftFunc, sdScaleFunc},

      (* Option values *)
      tangentsQ = TrueQ[OptionValue[QuantileEnvelopeSimple, "Tangents"]];

      (* Standardize *)
      sdShiftFunc = OptionValue[QuantileEnvelopeSimple, "StandardizingShiftFunction"];
      If[ TrueQ[sdShiftFunc === Automatic], sdShiftFunc = Mean];

      sdScaleFunc = OptionValue[QuantileEnvelopeSimple, "StandardizingScaleFunction"];
      If[ TrueQ[sdScaleFunc === Automatic], sdScaleFunc = InterquartileRange];

      center = sdShiftFunc @ data;
      scale = sdScaleFunc /@ Transpose[data];
      data = Map[(# - center) / scale &, data];

      (* Rotation matrices *)
      rmat = N[RotationMatrix[2 Pi / n]];
      rmats = NestList[rmat . # &, rmat, n - 1];
      qfuncs = Transpose[ Map[Function[{m}, Quantile[(m . Transpose[data])[[2]], probs]], rmats]];
      If[tangentsQ,
        rqfuncs = Map[Function[{qfs}, MapThread[ Flatten[Expand[{x1, y1} . #1 /. y1 -> #2]] &, {rmats, qfs}]], qfuncs];
        intPoints = Table[(
          t =
              Equal @@@ Transpose[{rqfuncs[[k, i]], rqfuncs[[k, If[i >= Length[rqfuncs[[k]]], 1, i + 1]]] /. x1 -> x2}];
          t = {x1, x2} /. ToRules[Reduce[t, {x1, x2}]];
          rqfuncs[[k, i]] /. x1 -> t[[1]]
        ), {k, 1, Length[rqfuncs]}, {i, 1, Length[rqfuncs[[k]]]}],
        (*ELSE*)

        intPoints = Map[Function[{qfs}, MapThread[{0, #2} . #1 &, {rmats, qfs}]], qfuncs];
      ];

      (* Reverse standardizing *)

      intPoints = Map[(# * scale + center) &, intPoints, {2}];
      intPoints
    ];


(**************************************************************)
(* QuantileEnvelopeRegion                                     *)
(**************************************************************)

QuantileEnvelopeRegion::qemat = "The first argument is expected to be a numeric two or three column data matrix.";

Clear[QuantileEnvelopeRegion];
QuantileEnvelopeRegion[points_?MatrixQ, quantile_?NumberQ, numberOfDirections_Integer] :=
    Which[
      Dimensions[points][[2]] == 2, QuantileEnvelopeRegion2D[points, quantile, numberOfDirections ],
      Dimensions[points][[2]] == 3, QuantileEnvelopeRegion3D[points, quantile, numberOfDirections ],
      True,
      Message[QuantileEnvelopeRegion::qemat]; $Failed
    ];

Clear[QuantileEnvelopeRegion2D];
QuantileEnvelopeRegion2D[points_?MatrixQ, quantile_?NumberQ, numberOfDirections_Integer] :=
    Block[{nd = numberOfDirections, dirs, rmats, qDirPoints, qRegion},
      dirs =
          N@ Table[{Cos[th], Sin[th]}, {th, 2 Pi / (10 nd), 2 Pi, 2 Pi / nd}];
      rmats = RotationMatrix[{{1, 0}, #}] & /@ dirs;
      qDirPoints =
          Flatten[Map[
            Function[{m}, Quantile[(m . Transpose[points])[[2]], quantile]],
            rmats]];
      qRegion =
          ImplicitRegion[ MapThread[(#1 . {x, y})[[2]] <= #2 &, {rmats, qDirPoints}], {x, y}];
      qRegion
    ] /; Dimensions[points][[2]] == 2 && 0 < quantile <= 1;


Clear[QuantileEnvelopeRegion3D];
QuantileEnvelopeRegion3D[points_?MatrixQ, quantile_?NumberQ, numberOfDirections_Integer] :=
    Block[{nd = numberOfDirections, dirs, rmats, qDirPoints, qRegion},
      dirs =
          N@Flatten[
            Table[{Cos[th] Cos[phi], Sin[th] Cos[phi], Sin[phi]},
              {th, 2 Pi / (10 nd), 2 Pi, 2 Pi / nd},
              {phi, -Pi, Pi, 2 Pi / nd}], 1];
      rmats = RotationMatrix[{{1, 0, 0}, #}] & /@ dirs;
      qDirPoints =
          Flatten[Map[
            Function[{m}, Quantile[(m . Transpose[points])[[3]], quantile]],
            rmats]];
      qRegion =
          ImplicitRegion[ MapThread[(#1 . {x, y, z})[[3]] <= #2 &, {rmats, qDirPoints}], {x, y, z}];
      qRegion
    ] /; Dimensions[points][[2]] == 3 && 0 < quantile <= 1;


End[];
EndPackage[];
