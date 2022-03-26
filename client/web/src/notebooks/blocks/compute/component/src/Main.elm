port module Main exposing (..)

import Animation
import Browser
import Browser.Events
import Chart as C
import Chart.Attributes as CA
import Circle2d
import Colors
import Dict exposing (Dict)
import Direction2d
import Element as E exposing (Color)
import Element.Background as Background
import Element.Border as Border
import Element.Events
import Element.Font as F
import Element.Input as I
import File.Download
import Geometry.Svg
import Graph
import Graph.Force as Force
import Graph.Layout
import GraphFile as GF exposing (EdgeId, kitesDefaultEdgeProp, kitesDefaultVertexProp)
import Html exposing (Html, input, text)
import Html.Attributes exposing (..)
import IntDict
import Json.Decode as Decode exposing (Decoder, fail, field, maybe)
import Json.Decode.Pipeline
import LineSegment2d exposing (LineSegment2d)
import List.Extra
import Point2d exposing (Point2d)
import Process
import Set exposing (Set)
import Svg as S exposing (Svg)
import Svg.Attributes as SA
import Svg.Keyed
import Task
import Time
import Triangle2d
import Url.Builder
import Url.Parser exposing (..)
import Vector2d



-- CONSTANTS


width : Int
width =
    800


debounceQueryInputMillis : Float
debounceQueryInputMillis =
    400


placeholderQuery : String
placeholderQuery =
    "repo:github\\.com/sourcegraph/sourcegraph$ content:output((\\w+) -> $1,$author) type:commit after:\"1 month ago\" count:all"


type alias Flags =
    { sourcegraphURL : String
    , isLightTheme : Maybe Bool
    , computeInput : Maybe ComputeInput
    }



-- MAIN


main : Program Decode.Value Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


type Animation
    = NoAnimation
    | ForceAnimation Force.State
    | TransitionAnimation
        { startGraph : GF.GraphFile
        , endGraph : GF.GraphFile
        , transitionState : Animation.State
        }



-- MODEL


type alias DataValue =
    { name : String
    , value : Float
    }


type alias DataFilter =
    { dataPoints : Int
    , sortByCount : Bool
    , reverse : Bool
    , excludeStopWords : Bool
    }


type Theme
    = Dark
    | Light


type alias Model =
    { sourcegraphURL : String
    , query : String
    , debounce : Int
    , dataFilter : DataFilter
    , selectedTab : Tab
    , resultsMap : Dict String DataValue
    , topicalMap : Dict String (Dict String DataValue) -- Dict Topic (Dict (Author, count))
    , alerts : List Alert
    , theme : Theme
    , animation : Animation
    , timeList : List Time.Posix
    , graph : GF.GraphFile

    -- Debug client only
    , serverless : Bool
    }


init : Decode.Value -> ( Model, Cmd Msg )
init json =
    let
        flags =
            case Decode.decodeValue flagsDecoder json of
                Ok result ->
                    result

                Err _ ->
                    -- no initial flags
                    { sourcegraphURL = ""
                    , isLightTheme = Nothing
                    , computeInput =
                        Just
                            { computeQueries = [ placeholderQuery ]
                            , experimentalOptions = Nothing
                            }
                    }

        experimentalOptions =
            case Maybe.andThen .experimentalOptions flags.computeInput of
                Just { dataPoints, sortByCount, reverse, excludeStopWords, activeTab } ->
                    { dataPoints = Maybe.withDefault 30 dataPoints
                    , sortByCount = Maybe.withDefault True sortByCount
                    , reverse = Maybe.withDefault False reverse
                    , excludeStopWords = Maybe.withDefault False excludeStopWords
                    , activeTab = Maybe.withDefault Chart (Maybe.map (tabFromString << .name) activeTab)
                    }

                Nothing ->
                    { dataPoints = 30
                    , sortByCount = True
                    , reverse = False
                    , excludeStopWords = False
                    , activeTab = Chart
                    }
    in
    ( { sourcegraphURL = flags.sourcegraphURL
      , query =
            case Maybe.map .computeQueries flags.computeInput of
                Just (query :: _) ->
                    query

                _ ->
                    placeholderQuery
      , dataFilter =
            { dataPoints = experimentalOptions.dataPoints
            , sortByCount = experimentalOptions.sortByCount
            , reverse = experimentalOptions.reverse
            , excludeStopWords = experimentalOptions.excludeStopWords
            }
      , theme =
            case flags.isLightTheme of
                Just True ->
                    Light

                _ ->
                    Dark
      , selectedTab = Graph
      , debounce = 0
      , resultsMap = Dict.empty
      , topicalMap = Dict.empty
      , alerts = []
      , serverless = False
      , animation = ForceAnimation Force.defaultForceState
      , timeList = []
      , graph =
            let
                g =
                    Graph.fromNodesAndEdges
                        []
                        []
                        |> Graph.Layout.circular { center = ( 300, 300 ), radius = 250 }
            in
            GF.new
                { graph = g
                , bags = Dict.empty
                , defaultVertexProperties = kitesDefaultVertexProp
                , defaultEdgeProperties = kitesDefaultEdgeProp
                }
      }
        |> reheatForce
    , Task.perform identity (Task.succeed RunCompute)
    )


reheatForce m =
    { m | animation = ForceAnimation Force.defaultForceState }



-- PORTS


type alias RawEvent =
    { data : String
    , eventType : Maybe String
    , id : Maybe String
    }


type alias ActiveTab =
    { name : String
    }


type alias ExperimentalOptions =
    { dataPoints : Maybe Int
    , sortByCount : Maybe Bool
    , reverse : Maybe Bool
    , excludeStopWords : Maybe Bool
    , activeTab : Maybe ActiveTab
    }


type alias ComputeInput =
    { computeQueries : List String
    , experimentalOptions : Maybe ExperimentalOptions
    }


port receiveEvent : (RawEvent -> msg) -> Sub msg


port openStream : ( String, Maybe String ) -> Cmd msg


port emitInput : ComputeInput -> Cmd msg



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ receiveEvent eventDecoder
        , animationFrame model
        ]


animationFrame : Model -> Sub Msg
animationFrame m =
    case m.animation of
        NoAnimation ->
            Sub.none

        TransitionAnimation _ ->
            Browser.Events.onAnimationFrameDelta TransitionTimeDelta

        ForceAnimation _ ->
            Browser.Events.onAnimationFrame ForceTick


eventDecoder : RawEvent -> Msg
eventDecoder event =
    case event.eventType of
        Just "results" ->
            OnResults (resultEventDecoder event.data)

        Just "done" ->
            ResultStreamDone

        Just "alert" ->
            OnAlert (alertEventDecoder event.data)

        _ ->
            NoOp


resultEventDecoder : String -> List Result
resultEventDecoder input =
    case Decode.decodeString (Decode.list resultDecoder) input of
        Ok results ->
            results

        Err _ ->
            []


alertEventDecoder : String -> List Alert
alertEventDecoder input =
    case Decode.decodeString alertDecoder input of
        Ok alert ->
            [ alert ]

        Err _ ->
            []



-- UPDATE


type Msg
    = -- User inputs
      OnQueryChanged String
    | OnDebounce
    | OnDataFilter DataFilterMsg
    | OnTabSelected Tab
    | OnDownloadData
      -- Data processing
    | RunCompute
    | OnResults (List Result)
    | OnAlert (List Alert)
    | ResultStreamDone
    | NoOp
      --
    | ForceTick Time.Posix
    | TransitionTimeDelta Float


type DataFilterMsg
    = OnDataPoints String
    | OnSortByCheckbox Bool
    | OnReverseCheckbox Bool
    | OnExcludeStopWordsCheckbox Bool


updateComputeInput : List String -> DataFilter -> Tab -> ComputeInput
updateComputeInput queries dataFilter selectedTab =
    { computeQueries = queries
    , experimentalOptions =
        Just
            { dataPoints = Just dataFilter.dataPoints
            , sortByCount = Just dataFilter.sortByCount
            , reverse = Just dataFilter.reverse
            , excludeStopWords = Just dataFilter.excludeStopWords
            , activeTab = Just { name = stringFromTab selectedTab }
            }
    }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        OnQueryChanged newQuery ->
            ( { model | query = newQuery, debounce = model.debounce + 1 }
            , Task.perform (\_ -> OnDebounce) (Process.sleep debounceQueryInputMillis)
            )

        OnDebounce ->
            if model.debounce - 1 == 0 then
                let
                    ( newModel, runCompute ) =
                        update RunCompute { model | debounce = model.debounce - 1 }
                in
                ( newModel
                , Cmd.batch
                    [ emitInput (updateComputeInput [ model.query ] model.dataFilter model.selectedTab)
                    , runCompute
                    ]
                )

            else
                ( { model | debounce = model.debounce - 1 }, Cmd.none )

        OnDataFilter dataFilterMsg ->
            let
                newDataFilter =
                    updateDataFilter dataFilterMsg model.dataFilter
            in
            ( { model | dataFilter = newDataFilter }
            , emitInput (updateComputeInput [ model.query ] newDataFilter model.selectedTab)
            )

        OnTabSelected selectedTab ->
            ( { model | selectedTab = selectedTab }
            , emitInput (updateComputeInput [ model.query ] model.dataFilter selectedTab)
            )

        OnDownloadData ->
            let
                data =
                    Dict.toList model.resultsMap
                        |> List.map Tuple.second
                        |> filterData model.dataFilter
            in
            ( model, File.Download.string "notebook-compute-data.txt" "text/plain" (String.join "\n" (List.map .name data)) )

        RunCompute ->
            if model.serverless then
                ( { model | resultsMap = exampleResultsMap }, Cmd.none )

            else
                let
                    alerts =
                        if (String.contains "type:commit" model.query || String.contains "type:diff" model.query) && not (String.contains "count:all" model.query) then
                            [ { title = "Heads up"
                              , description = "This data may be incomplete! Add `count:all` to this query? Avoid doing this all the time though... 🤣"
                              }
                            ]

                        else
                            []
                in
                ( { model | resultsMap = Dict.empty, alerts = alerts, topicalMap = Dict.empty }
                , Cmd.batch
                    [ openStream
                        ( Url.Builder.crossOrigin
                            model.sourcegraphURL
                            [ ".api", "compute", "stream" ]
                            [ Url.Builder.string "q" model.query ]
                        , Nothing
                        )
                    ]
                )

        OnResults r ->
            let
                parsedResults =
                    parseResults r

                newTopicalMap =
                    List.foldl updateTopicalMap model.topicalMap parsedResults
            in
            ( { model
                | resultsMap = List.foldl updateResultsMap model.resultsMap parsedResults
                , topicalMap = newTopicalMap
                , animation = ForceAnimation Force.defaultForceState
                , graph = updateNewGraph newTopicalMap
              }
            , Cmd.none
            )

        OnAlert alert ->
            ( { model | alerts = List.append model.alerts alert }, Cmd.none )

        ResultStreamDone ->
            ( model, Cmd.none )

        NoOp ->
            ( model, Cmd.none )

        ForceTick t ->
            case model.animation of
                ForceAnimation forceState ->
                    if Force.isCompleted forceState then
                        ( { model | animation = NoAnimation }, Cmd.none )

                    else
                        let
                            ( newForceState, newGraph ) =
                                GF.forceTick forceState model.graph
                        in
                        ( { model
                            | animation = ForceAnimation newForceState
                            , timeList = t :: model.timeList |> List.take 42
                            , graph = newGraph
                          }
                        , Cmd.none
                        )

                _ ->
                    ( model, Cmd.none )

        TransitionTimeDelta timeDelta ->
            case model.animation of
                TransitionAnimation tA ->
                    if Animation.hasFinished tA.transitionState then
                        ( { model | animation = NoAnimation }, Cmd.none )

                    else
                        ( { model | animation = TransitionAnimation { tA | transitionState = Animation.update timeDelta tA.transitionState } }, Cmd.none )

                _ ->
                    ( model, Cmd.none )


updateDataFilter : DataFilterMsg -> DataFilter -> DataFilter
updateDataFilter msg dataFilter =
    case msg of
        OnSortByCheckbox sortByCount ->
            { dataFilter | sortByCount = sortByCount }

        OnReverseCheckbox reverse ->
            { dataFilter | reverse = reverse }

        OnExcludeStopWordsCheckbox excludeStopWords ->
            { dataFilter | excludeStopWords = excludeStopWords }

        OnDataPoints i ->
            let
                newDataPoints =
                    case String.toInt i of
                        Just n ->
                            n

                        Nothing ->
                            0
            in
            { dataFilter | dataPoints = newDataPoints }



-- VIEW


table : Theme -> List DataValue -> E.Element Msg
table theme data =
    let
        headerAttrs =
            [ F.bold
            , F.size 12
            , F.color (fontColor theme)
            ]
    in
    E.el [ E.padding 10, E.centerX ]
        (E.table [ E.width E.fill ]
            { data = data
            , columns =
                [ { header = E.el headerAttrs (E.text " ")
                  , width = E.fillPortion 2
                  , view =
                        \v ->
                            E.el [ E.padding 10 ]
                                (E.el
                                    [ E.width E.fill
                                    , E.padding 10
                                    , Border.rounded 5
                                    , Border.width 1
                                    ]
                                    (E.paragraph [ E.width (E.fill |> E.maximum 600) ] [ E.text v.name ])
                                )
                  }
                , { header = E.el (headerAttrs ++ [ F.alignRight ]) (E.text "Count")
                  , width = E.fillPortion 1
                  , view =
                        \v ->
                            E.el
                                [ E.centerY
                                , F.size 12
                                , F.color (fontColor theme)
                                , F.alignRight
                                ]
                                (E.text (String.fromFloat v.value))
                  }
                ]
            }
        )


histogram : Theme -> List DataValue -> E.Element Msg
histogram theme data =
    E.el
        [ E.width E.fill
        , E.height (E.fill |> E.minimum 400)
        , E.centerX
        , E.alignTop
        , E.padding 30
        ]
        (E.html
            (C.chart
                [ CA.height 300, CA.width (toFloat width) ]
                [ C.bars
                    [ CA.spacing 0.0 ]
                    [ C.bar .value [ CA.color "#A112FF", CA.roundTop 0.2 ] ]
                    data
                , C.binLabels .name [ CA.moveDown 25, CA.rotate 45, CA.alignRight ]
                , C.barLabels [ CA.moveDown 12, CA.color "white", CA.fontSize 12 ]
                ]
            )
        )


dataView : Theme -> List DataValue -> E.Element Msg
dataView theme data =
    E.row [ E.width E.fill ]
        [ E.el [ E.padding 10, E.alignLeft ]
            (E.column []
                (List.map
                    (\d ->
                        E.paragraph
                            [ E.paddingEach
                                { bottom = 2
                                , top = 0
                                , left = 0
                                , right = 0
                                }
                            , E.width (E.fill |> E.maximum 600)
                            ]
                            [ E.text d.name ]
                    )
                    data
                )
            )
        , E.el
            [ E.paddingXY 0 10
            , E.alignRight
            , E.alignTop
            ]
            (I.button
                [ Border.width 1
                , Border.rounded 3
                , E.padding 10
                ]
                { onPress = Just OnDownloadData, label = E.text "Download Data" }
            )
        ]


wantEdges : List String -> Dict String Int -> List ( Int, String )
wantEdges authors lookup =
    List.foldl
        (\a l ->
            case Dict.get a lookup of
                Just exists ->
                    ( exists, a ) :: l

                Nothing ->
                    -- invariant: it exists. this function just associates authors for a topic with their ids
                    l
        )
        []
        authors


updateNewGraph topicalMap =
    let
        ( graph, _, _ ) =
            topicalMap
                |> Dict.toList
                -- sort each author list per topic by count
                |> List.map (\( topic, author ) -> ( topic, Dict.toList author |> List.sortBy (\( _, { value } ) -> value) |> List.reverse ))
                -- sort overall list by using first author count of each topic
                |> List.sortBy (\( _, authors ) -> List.length authors)
                |> List.reverse
                |> List.map (\( x, authors ) -> ( x, List.take 10 authors ))
                -- NUMBER OF AUTHORS
                |> List.take 10
                -- NUMBER OF TOPICS
                |> (\x ->
                        let
                            _ =
                                Debug.log "START" "START"
                        in
                        x
                   )
                |> List.map (\i -> Debug.log "hm" i)
                |> List.foldl
                    (\( topic, authors ) ( g, lookup, i ) ->
                        let
                            topicId =
                                i

                            nextId =
                                i + 1

                            ( newLookup, freshIndex, newAuthorNodes ) =
                                List.foldl
                                    (\a ( d, authorIndex, authorNodes ) ->
                                        let
                                            nextIndex =
                                                authorIndex + 1
                                        in
                                        ( Dict.update a
                                            (\id ->
                                                case id of
                                                    Just existing ->
                                                        Just existing

                                                    Nothing ->
                                                        Just nextIndex
                                            )
                                            d
                                        , nextIndex
                                        , a :: authorNodes
                                        )
                                    )
                                    ( lookup, nextId, [] )
                                    (List.map Tuple.first authors)

                            authorNodeEdges =
                                wantEdges newAuthorNodes newLookup

                            incomingEdges =
                                List.foldl
                                    (\( authorId, _ ) d ->
                                        IntDict.insert authorId
                                            { kitesDefaultEdgeProp
                                                | thickness = 1
                                                , strength = 0.002
                                                , color = Colors.darkGray
                                                , opacity = 0.8
                                                , distance = 80
                                            }
                                            d
                                    )
                                    IntDict.empty
                                    authorNodeEdges

                            gg =
                                List.foldl
                                    (\( authorId, authorName ) innerG ->
                                        innerG
                                            |> Graph.update authorId
                                                (\context ->
                                                    case context of
                                                        Just c ->
                                                            Just c

                                                        Nothing ->
                                                            Just
                                                                { node =
                                                                    { id = authorId
                                                                    , label =
                                                                        { kitesDefaultVertexProp
                                                                            | label = authorName
                                                                            , position = Point2d.fromCoordinates ( 500.0, 500.0 )
                                                                            , color = Colors.blue
                                                                            , manyBodyStrength = -100
                                                                        }
                                                                    }
                                                                , incoming = IntDict.empty
                                                                , outgoing = IntDict.empty
                                                                }
                                                )
                                    )
                                    g
                                    authorNodeEdges

                            newG =
                                gg
                                    |> Graph.update topicId
                                        (\context ->
                                            case context of
                                                Just c ->
                                                    Just c

                                                Nothing ->
                                                    Just
                                                        { node =
                                                            { id = topicId
                                                            , label =
                                                                { kitesDefaultVertexProp
                                                                    | label = topic
                                                                    , position = Point2d.fromCoordinates ( 600.0, 600.0 )
                                                                    , color = Colors.turquoise
                                                                    , manyBodyStrength = -100
                                                                }
                                                            }
                                                        , incoming = incomingEdges
                                                        , outgoing = IntDict.empty
                                                        }
                                        )
                        in
                        ( newG, newLookup, freshIndex + 1 )
                    )
                    ( Graph.empty, Dict.empty, 0 )

        graphFile =
            GF.new
                { graph = Graph.Layout.circular { center = ( 600, 600 ), radius = 150 } graph
                , bags = Dict.empty
                , defaultVertexProperties = kitesDefaultVertexProp
                , defaultEdgeProperties = kitesDefaultEdgeProp
                }
    in
    graphFile


graphView : Theme -> Model -> E.Element Msg
graphView theme model =
    E.html <|
        S.svg
            [ SA.width "1000" -- FIXME
            , SA.height "1000" -- FIXMe
            , SA.viewBox "-100 -300 1000 1000"
            ]
            [ viewEdges model.graph
            , viewVertices model.graph
            ]


emptySvgElement : Svg msg
emptySvgElement =
    S.g [] []


arrow :
    { lineSegment : LineSegment2d
    , color : Color
    , thickness : Float
    , headWidth : Float
    , headLength : Float
    }
    -> Html Msg
arrow { lineSegment, color, thickness, headWidth, headLength } =
    let
        dir =
            LineSegment2d.direction lineSegment
                |> Maybe.withDefault Direction2d.positiveX

        angle =
            Direction2d.toAngle dir

        vecFromOriginToEndPoint =
            LineSegment2d.endPoint lineSegment
                |> Point2d.coordinates
                |> Vector2d.fromComponents

        arrowHead =
            Triangle2d.fromVertices
                ( Point2d.fromCoordinates ( 0, -headWidth / 2 )
                , Point2d.fromCoordinates ( 0, headWidth / 2 )
                , Point2d.fromCoordinates ( headLength, 0 )
                )
                |> Triangle2d.rotateAround Point2d.origin angle
                |> Triangle2d.translateBy vecFromOriginToEndPoint
                |> Triangle2d.translateIn dir -headLength
    in
    S.g []
        [ Geometry.Svg.lineSegment2d
            [ SA.stroke (Colors.toString color)
            , SA.strokeWidth (String.fromFloat thickness)
            ]
            (LineSegment2d.from
                (LineSegment2d.startPoint lineSegment)
                (LineSegment2d.endPoint lineSegment
                    |> Point2d.translateIn dir -headLength
                )
            )
        , Geometry.Svg.triangle2d
            [ SA.fill (Colors.toString color)
            ]
            arrowHead
        ]


edgeIdToString : EdgeId -> String
edgeIdToString ( from, to ) =
    String.fromInt from ++ " → " ++ String.fromInt to


viewEdges : GF.GraphFile -> Html Msg
viewEdges graphFile =
    let
        labelDistance =
            10

        labelPosition : LineSegment2d -> Point2d
        labelPosition edgeLine =
            let
                fromEdgeMidpointToLabelMidpoint =
                    edgeLine
                        |> LineSegment2d.perpendicularDirection
                        |> Maybe.withDefault Direction2d.negativeY
                        |> Direction2d.reverse
                        |> Vector2d.withLength labelDistance
            in
            edgeLine
                |> LineSegment2d.midpoint
                |> Point2d.translateBy fromEdgeMidpointToLabelMidpoint

        edgeWithKey { from, to, label } =
            case ( GF.getVertexProperties from graphFile, GF.getVertexProperties to graphFile ) of
                ( Just v, Just w ) ->
                    let
                        dir =
                            Direction2d.from v.position w.position
                                |> Maybe.withDefault Direction2d.positiveX

                        edgeStart =
                            v.position |> Point2d.translateIn dir v.radius

                        edgeEnd =
                            w.position |> Point2d.translateIn dir -w.radius

                        edgeLine =
                            LineSegment2d.from edgeStart edgeEnd

                        lP =
                            labelPosition edgeLine

                        eL =
                            S.text_
                                [ SA.x
                                    (String.fromFloat (Point2d.xCoordinate lP))
                                , SA.y
                                    (String.fromFloat (Point2d.yCoordinate lP))
                                , SA.textAnchor "middle"
                                , SA.fontSize (String.fromFloat label.labelSize)
                                , SA.fill (Colors.toString label.labelColor)
                                ]
                                [ S.text label.label ]

                        edgeLabel =
                            if label.labelIsVisible then
                                eL

                            else
                                emptySvgElement

                        invisibleBackGroundHandle =
                            Geometry.Svg.lineSegment2d
                                [ SA.stroke "red"
                                , SA.strokeOpacity "0"
                                , SA.strokeWidth (String.fromFloat (label.thickness + 6))
                                ]
                                edgeLine
                    in
                    ( edgeIdToString ( from, to )
                    , S.g
                        [ SA.opacity (String.fromFloat label.opacity)

                        {--
                        , SE.onMouseDown (MouseDownOnEdge ( from, to ))
                        , SE.onMouseUp (MouseUpOnEdge ( from, to ))
                        , SE.onMouseOver (MouseOverEdge ( from, to ))
                        , SE.onMouseOut (MouseOutEdge ( from, to ))
-}
                        ]
                        [ invisibleBackGroundHandle
                        , arrow
                            { lineSegment = edgeLine
                            , color = label.color
                            , thickness = label.thickness
                            , headWidth = 0 * label.thickness -- Changed from 3 to 0
                            , headLength = 0 * label.thickness
                            }
                        , edgeLabel
                        ]
                    )

                _ ->
                    --Debug.todo "GUI ALLOWED SOMETHING IMPOSSIBLE" <|
                    ( "", emptySvgElement )
    in
    Svg.Keyed.node "g" [] (graphFile |> GF.getEdges |> List.map edgeWithKey)


viewVertices : GF.GraphFile -> Html Msg
viewVertices graphFile =
    let
        pin fixed radius =
            if fixed then
                Geometry.Svg.circle2d
                    [ SA.fill "red"
                    , SA.stroke "white"
                    ]
                    (Point2d.origin |> Circle2d.withRadius (radius / 2))

            else
                emptySvgElement

        viewVertex { id, label } =
            let
                ( x, y ) =
                    Point2d.coordinates label.position

                ( labelAnchor, labelX, labelY ) =
                    case label.labelPosition of
                        GF.LabelTopLeft ->
                            ( "end"
                            , -label.radius - 4
                            , -label.radius - 4
                            )

                        GF.LabelTop ->
                            ( "middle"
                            , 0
                            , -label.radius - 4
                            )

                        GF.LabelTopRight ->
                            ( "start"
                            , label.radius + 4
                            , -label.radius - 4
                            )

                        GF.LabelCenter ->
                            ( "middle"
                            , 0
                            , 0.39 * label.labelSize
                            )

                        GF.LabelLeft ->
                            ( "end"
                            , -label.radius - 4
                            , 0.39 * label.labelSize
                            )

                        GF.LabelRight ->
                            ( "start"
                            , label.radius + 4
                            , 0.39 * label.labelSize
                            )

                        GF.LabelBottomLeft ->
                            ( "end"
                            , -label.radius - 4
                            , label.radius + label.labelSize
                            )

                        GF.LabelBottom ->
                            ( "middle"
                            , 0
                            , label.radius + label.labelSize
                            )

                        GF.LabelBottomRight ->
                            ( "start"
                            , label.radius + 4
                            , label.radius + label.labelSize
                            )

                vertexLabel =
                    if label.labelIsVisible then
                        S.text_
                            [ SA.fill (Colors.toString label.labelColor)
                            , SA.fontSize (String.fromFloat label.labelSize)
                            , SA.textAnchor labelAnchor
                            , SA.x (String.fromFloat labelX)
                            , SA.y (String.fromFloat labelY)
                            ]
                            [ S.text label.label
                            ]

                    else
                        emptySvgElement

                circleSvg : Color -> Float -> Svg msg
                circleSvg c r =
                    Geometry.Svg.circle2d
                        [ SA.fill (Colors.toString c) ]
                        (Point2d.origin |> Circle2d.withRadius r)

                backGroundCircleForBorder =
                    circleSvg label.borderColor label.radius

                innerCircle =
                    circleSvg label.color (label.radius - label.borderWidth)
            in
            ( String.fromInt id
            , S.g
                [ SA.transform <| "translate(" ++ String.fromFloat x ++ "," ++ String.fromFloat y ++ ")"
                , SA.opacity (String.fromFloat label.opacity)

                {--TODO
                , SE.onMouseDown (MouseDownOnVertex id)
                , SE.onMouseUp (MouseUpOnVertex id)
                , SE.onMouseOver (MouseOverVertex id)
                , SE.onMouseOut (MouseOutVertex id)
-}
                ]
                [ backGroundCircleForBorder
                , innerCircle
                , pin label.fixed label.radius
                , vertexLabel
                ]
            )
    in
    Svg.Keyed.node "g" [] (graphFile |> GF.getVertices |> List.map viewVertex)


viewDataFilter : Theme -> DataFilter -> E.Element DataFilterMsg
viewDataFilter theme dataFilter =
    E.row [ E.paddingXY 0 10 ]
        [ I.text [ E.width (E.fill |> E.maximum 65), F.center, Background.color (textInputBackgroundColor theme) ]
            { onChange = OnDataPoints
            , placeholder = Nothing
            , text =
                case dataFilter.dataPoints of
                    0 ->
                        ""

                    n ->
                        String.fromInt n
            , label = I.labelHidden ""
            }
        , I.checkbox [ E.paddingXY 10 0 ]
            { onChange = OnSortByCheckbox
            , icon = I.defaultCheckbox
            , checked = dataFilter.sortByCount
            , label = I.labelRight [] (E.text "sort by count")
            }
        , I.checkbox [ E.paddingXY 10 0 ]
            { onChange = OnReverseCheckbox
            , icon = I.defaultCheckbox
            , checked = dataFilter.reverse
            , label = I.labelRight [] (E.text "reverse")
            }
        , I.checkbox [ E.paddingXY 10 0 ]
            { onChange = OnExcludeStopWordsCheckbox
            , icon = I.defaultCheckbox
            , checked = dataFilter.excludeStopWords
            , label = I.labelRight [] (E.text "exclude stop words")
            }
        ]


inputRow : Model -> E.Element Msg
inputRow model =
    E.el [ E.centerX, E.width E.fill ]
        (E.column [ E.width E.fill ]
            [ I.text [ Background.color (textInputBackgroundColor model.theme) ]
                { onChange = OnQueryChanged
                , placeholder = Nothing
                , text = model.query
                , label = I.labelHidden ""
                }
            , E.map OnDataFilter (viewDataFilter model.theme model.dataFilter)
            ]
        )


type Tab
    = Chart
    | Table
    | Data
    | Graph


tabFromString : String -> Tab
tabFromString s =
    case s of
        "chart" ->
            Chart

        "table" ->
            Table

        "data" ->
            Data

        _ ->
            Chart


stringFromTab : Tab -> String
stringFromTab t =
    case t of
        Chart ->
            "chart"

        Graph ->
            "graph"

        Table ->
            "table"

        Data ->
            "data"


tabColor =
    { skyBlue = E.rgb255 0x00 0xCB 0xEC
    , vividViolet = E.rgb255 0xA1 0x12 0xFF
    , vermillion = E.rgb255 0xFF 0x55 0x43
    }


tab : Tab -> Tab -> E.Element Msg
tab thisTab selectedTab =
    let
        isSelected =
            thisTab == selectedTab

        padOffset =
            if isSelected then
                0

            else
                2

        borderWidths =
            if isSelected then
                { left = 1, top = 1, right = 1, bottom = 0 }

            else
                { bottom = 1, top = 0, left = 0, right = 0 }

        corners =
            if isSelected then
                { topLeft = 6, topRight = 6, bottomLeft = 0, bottomRight = 0 }

            else
                { topLeft = 0, topRight = 0, bottomLeft = 0, bottomRight = 0 }

        color =
            case selectedTab of
                Graph ->
                    tabColor.vividViolet

                Chart ->
                    tabColor.vividViolet

                Table ->
                    tabColor.vermillion

                Data ->
                    tabColor.skyBlue

        text =
            case thisTab of
                Graph ->
                    "Graph"

                Chart ->
                    "Chart"

                Table ->
                    "Table"

                Data ->
                    "Data"
    in
    E.el
        [ Border.widthEach borderWidths
        , Border.roundEach corners
        , Border.color color
        , Element.Events.onClick (OnTabSelected thisTab)
        , E.htmlAttribute (Html.Attributes.style "cursor" "pointer")
        , E.width E.fill
        ]
        (E.el
            [ E.centerX
            , E.width E.fill
            , E.centerY
            , E.paddingEach { left = 30, right = 30, top = 10 + padOffset, bottom = 10 - padOffset }
            ]
            (E.text text)
        )


outputAlerts : List Alert -> E.Element Msg
outputAlerts alerts =
    E.column [ E.width E.fill, F.size 10, E.paddingEach { top = 0, left = 0, right = 0, bottom = 10 }, E.spacing 3 ]
        (List.map
            (\a ->
                E.el
                    [ Background.color alertBackgroundColor
                    , E.paddingEach { top = 5, bottom = 5, left = 10, right = 10 }
                    , Border.rounded 2
                    ]
                    (E.paragraph [] [ E.text (a.title ++ ": " ++ a.description) ])
            )
            alerts
        )


outputRow : Tab -> E.Element Msg
outputRow selectedTab =
    E.row [ E.centerX, E.width E.fill ]
        [ tab Graph selectedTab
        , tab Chart selectedTab
        , tab Table selectedTab
        , tab Data selectedTab
        ]


view : Model -> Html Msg
view model =
    E.layout
        [ E.width E.fill
        , F.family [ F.typeface "Fira Code", F.typeface "Monaco" ]
        , F.size 12
        , F.color (fontColor model.theme)
        , Background.color (backgroundColor model.theme)
        ]
        (E.row [ E.centerX, E.width (E.fill |> E.maximum width) ]
            [ E.column [ E.centerX, E.width (E.fill |> E.maximum width), E.paddingXY 20 20 ]
                [ inputRow model
                , outputAlerts model.alerts
                , outputRow model.selectedTab
                , let
                    data =
                        Dict.toList model.resultsMap
                            |> List.map Tuple.second
                            |> filterData model.dataFilter
                  in
                  case model.selectedTab of
                    Graph ->
                        graphView model.theme model

                    Chart ->
                        histogram model.theme data

                    Table ->
                        table model.theme data

                    Data ->
                        dataView model.theme data
                ]
            ]
        )



-- DATA LOGIC


parseResults : List Result -> List String
parseResults l =
    List.filterMap
        (\r ->
            case r of
                Output v ->
                    String.split "\n" v.value
                        |> List.filter (not << String.isEmpty)
                        |> Just

                ReplaceInPlace v ->
                    Just [ v.value ]
        )
        l
        |> List.concat


updateResultsMap : String -> Dict String DataValue -> Dict String DataValue
updateResultsMap textResult =
    Dict.update
        textResult
        (\v ->
            case v of
                Nothing ->
                    Just { name = textResult, value = 1 }

                Just existing ->
                    Just { existing | value = existing.value + 1 }
        )


updateTopicalMap : String -> Dict String (Dict String DataValue) -> Dict String (Dict String DataValue)
updateTopicalMap topicAuthorPair =
    let
        ( topic, author ) =
            case String.split "," topicAuthorPair of
                t :: a :: _ ->
                    ( String.toLower t, a )

                _ ->
                    ( "nothing", "nothing" )
    in
    case List.Extra.find (\w -> Set.member w stopWords) (String.split " " topic) of
        Nothing ->
            identity

        Just _ ->
            Dict.update
                topic
                (\v ->
                    case v of
                        Nothing ->
                            Just (Dict.fromList [ ( "author", { name = author, value = 1 } ) ])

                        Just existingTopic ->
                            Just
                                (Dict.update
                                    author
                                    (\a ->
                                        case a of
                                            Nothing ->
                                                Just { name = author, value = 1 }

                                            Just existingAuthor ->
                                                Just { existingAuthor | value = existingAuthor.value + 1 }
                                    )
                                    existingTopic
                                )
                )


filterData : DataFilter -> List DataValue -> List DataValue
filterData { dataPoints, sortByCount, reverse, excludeStopWords } data =
    let
        pipeSort =
            if sortByCount then
                List.sortWith
                    (\l r ->
                        if l.value < r.value then
                            GT

                        else if l.value > r.value then
                            LT

                        else
                            EQ
                    )

            else
                identity
    in
    let
        pipeReverse =
            if reverse then
                List.reverse

            else
                identity
    in
    let
        pipeStopWords =
            if excludeStopWords then
                List.filter (\{ name } -> not (Set.member (String.toLower name) stopWords))

            else
                identity
    in
    data
        |> pipeStopWords
        |> pipeSort
        |> pipeReverse
        |> List.take dataPoints
        |> pipeReverse



-- STREAMING RESULT TYPES


type Result
    = Output TextResult
    | ReplaceInPlace TextResult


type alias TextResult =
    { value : String
    , repository : Maybe String
    , commit : Maybe String
    , path : Maybe String
    }


type alias Alert =
    { title : String
    , description : String
    }



-- DECODERS


flagsDecoder : Decoder Flags
flagsDecoder =
    Decode.succeed Flags
        |> Json.Decode.Pipeline.required "sourcegraphURL" Decode.string
        |> Json.Decode.Pipeline.optional "isLightTheme" (Decode.maybe Decode.bool) Nothing
        |> Json.Decode.Pipeline.required "computeInput" (Decode.nullable computeInputDecoder)


computeInputDecoder : Decoder ComputeInput
computeInputDecoder =
    Decode.succeed ComputeInput
        |> Json.Decode.Pipeline.required "computeQueries" (Decode.list Decode.string)
        |> Json.Decode.Pipeline.optional "experimentalOptions" (Decode.maybe experimentalOptionsDecoder) Nothing


activeTabDecoder : Decoder ActiveTab
activeTabDecoder =
    Decode.succeed ActiveTab
        |> Json.Decode.Pipeline.required "name" Decode.string


experimentalOptionsDecoder : Decoder ExperimentalOptions
experimentalOptionsDecoder =
    Decode.succeed ExperimentalOptions
        |> Json.Decode.Pipeline.optional "dataPoints" (Decode.maybe Decode.int) Nothing
        |> Json.Decode.Pipeline.optional "sortByCount" (Decode.maybe Decode.bool) Nothing
        |> Json.Decode.Pipeline.optional "reverse" (Decode.maybe Decode.bool) Nothing
        |> Json.Decode.Pipeline.optional "excludeStopWords" (Decode.maybe Decode.bool) Nothing
        |> Json.Decode.Pipeline.optional "activeTab" (Decode.maybe activeTabDecoder) Nothing


resultDecoder : Decoder Result
resultDecoder =
    field "kind" Decode.string
        |> Decode.andThen
            (\t ->
                case t of
                    "replace-in-place" ->
                        textResultDecoder
                            |> Decode.map ReplaceInPlace

                    "output" ->
                        textResultDecoder
                            |> Decode.map Output

                    _ ->
                        fail ("Unrecognized type " ++ t)
            )


textResultDecoder : Decoder TextResult
textResultDecoder =
    Decode.succeed TextResult
        |> Json.Decode.Pipeline.required "value" Decode.string
        |> Json.Decode.Pipeline.optional "repository" (maybe Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "commit" (maybe Decode.string) Nothing
        |> Json.Decode.Pipeline.optional "path" (maybe Decode.string) Nothing


alertDecoder : Decoder Alert
alertDecoder =
    Decode.succeed Alert
        |> Json.Decode.Pipeline.required "title" Decode.string
        |> Json.Decode.Pipeline.required "description" Decode.string



-- STYLING


backgroundColor : Theme -> E.Color
backgroundColor theme =
    case theme of
        Dark ->
            E.rgb255 0x18 0x1B 0x26

        Light ->
            E.rgb255 0xFF 0xFF 0xFF


fontColor : Theme -> E.Color
fontColor theme =
    case theme of
        Dark ->
            E.rgb255 0xFF 0xFF 0xFF

        Light ->
            E.rgb255 0x34 0x3A 0x4D


textInputBackgroundColor : Theme -> E.Color
textInputBackgroundColor theme =
    case theme of
        Dark ->
            E.rgb255 0x1D 0x22 0x2F

        Light ->
            E.rgb 0xFF 0xFF 0xFF


alertBackgroundColor : E.Color
alertBackgroundColor =
    E.rgb255 0x9C 0x65 0x00



-- DEBUG DATA


exampleResultsMap : Dict String DataValue
exampleResultsMap =
    [ { name = "Errorf"
      , value = 10.0
      }
    , { name = "Func\nmulti\nline"
      , value = 5.0
      }
    , { name = "Qux"
      , value = 2.0
      }
    ]
        |> List.map (\d -> ( d.name, d ))
        |> Dict.fromList



-- STOP WORD DATA


stopWords : Set String
stopWords =
    Set.fromList [ "authored", "add", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "'ll", "'tis", "'twas", "'ve", "10", "39", "a", "a's", "able", "ableabout", "about", "above", "abroad", "abst", "accordance", "according", "accordingly", "across", "act", "actually", "ad", "added", "adj", "adopted", "ae", "af", "affected", "affecting", "affects", "after", "afterwards", "ag", "again", "against", "ago", "ah", "ahead", "ai", "ain't", "aint", "al", "all", "allow", "allows", "almost", "alone", "along", "alongside", "already", "also", "although", "always", "am", "amid", "amidst", "among", "amongst", "amoungst", "amount", "an", "and", "announce", "another", "any", "anybody", "anyhow", "anymore", "anyone", "anything", "anyway", "anyways", "anywhere", "ao", "apart", "apparently", "appear", "appreciate", "appropriate", "approximately", "aq", "ar", "are", "area", "areas", "aren", "aren't", "arent", "arise", "around", "arpa", "as", "aside", "ask", "asked", "asking", "asks", "associated", "at", "au", "auth", "available", "aw", "away", "awfully", "az", "b", "ba", "back", "backed", "backing", "backs", "backward", "backwards", "bb", "bd", "be", "became", "because", "become", "becomes", "becoming", "been", "before", "beforehand", "began", "begin", "beginning", "beginnings", "begins", "behind", "being", "beings", "believe", "below", "beside", "besides", "best", "better", "between", "beyond", "bf", "bg", "bh", "bi", "big", "bill", "billion", "biol", "bj", "bm", "bn", "bo", "both", "bottom", "br", "brief", "briefly", "bs", "bt", "but", "buy", "bv", "bw", "by", "bz", "c", "c'mon", "c's", "ca", "call", "came", "can", "can't", "cannot", "cant", "caption", "case", "cases", "cause", "causes", "cc", "cd", "certain", "certainly", "cf", "cg", "ch", "changes", "ci", "ck", "cl", "clear", "clearly", "click", "cm", "cmon", "cn", "co", "co.", "com", "come", "comes", "computer", "con", "concerning", "consequently", "consider", "considering", "contain", "containing", "contains", "copy", "corresponding", "could", "could've", "couldn", "couldn't", "couldnt", "course", "cr", "cry", "cs", "cu", "currently", "cv", "cx", "cy", "cz", "d", "dare", "daren't", "darent", "date", "de", "dear", "definitely", "describe", "described", "despite", "detail", "did", "didn", "didn't", "didnt", "differ", "different", "differently", "directly", "dj", "dk", "dm", "do", "does", "doesn", "doesn't", "doesnt", "doing", "don", "don't", "done", "dont", "doubtful", "down", "downed", "downing", "downs", "downwards", "due", "during", "dz", "e", "each", "early", "ec", "ed", "edu", "ee", "effect", "eg", "eh", "eight", "eighty", "either", "eleven", "else", "elsewhere", "empty", "end", "ended", "ending", "ends", "enough", "entirely", "er", "es", "especially", "et", "et-al", "etc", "even", "evenly", "ever", "evermore", "every", "everybody", "everyone", "everything", "everywhere", "ex", "exactly", "example", "except", "f", "face", "faces", "fact", "facts", "fairly", "far", "farther", "felt", "few", "fewer", "ff", "fi", "fifteen", "fifth", "fifty", "fify", "fill", "find", "finds", "fire", "first", "five", "fix", "fj", "fk", "fm", "fo", "followed", "following", "follows", "for", "forever", "former", "formerly", "forth", "forty", "forward", "found", "four", "fr", "free", "from", "front", "full", "fully", "further", "furthered", "furthering", "furthermore", "furthers", "fx", "g", "ga", "gave", "gb", "gd", "ge", "general", "generally", "get", "gets", "getting", "gf", "gg", "gh", "gi", "give", "given", "gives", "giving", "gl", "gm", "gmt", "gn", "go", "goes", "going", "gone", "good", "goods", "got", "gotten", "gov", "gp", "gq", "gr", "great", "greater", "greatest", "greetings", "group", "grouped", "grouping", "groups", "gs", "gt", "gu", "gw", "gy", "h", "had", "hadn't", "hadnt", "half", "happens", "hardly", "has", "hasn", "hasn't", "hasnt", "have", "haven", "haven't", "havent", "having", "he", "he'd", "he'll", "he's", "hed", "hell", "hello", "help", "hence", "her", "here", "here's", "hereafter", "hereby", "herein", "heres", "hereupon", "hers", "herself", "herse”", "hes", "hi", "hid", "high", "higher", "highest", "him", "himself", "himse”", "his", "hither", "hk", "hm", "hn", "home", "homepage", "hopefully", "how", "how'd", "how'll", "how's", "howbeit", "however", "hr", "ht", "htm", "html", "http", "hu", "hundred", "i", "i'd", "i'll", "i'm", "i've", "i.e.", "id", "ie", "if", "ignored", "ii", "il", "ill", "im", "immediate", "immediately", "importance", "important", "in", "inasmuch", "inc", "inc.", "indeed", "index", "indicate", "indicated", "indicates", "information", "inner", "inside", "insofar", "instead", "int", "interest", "interested", "interesting", "interests", "into", "invention", "inward", "io", "iq", "ir", "is", "isn", "isn't", "isnt", "it", "it'd", "it'll", "it's", "itd", "itll", "its", "itself", "itse”", "ive", "j", "je", "jm", "jo", "join", "jp", "just", "k", "ke", "keep", "keeps", "kept", "keys", "kg", "kh", "ki", "kind", "km", "kn", "knew", "know", "known", "knows", "kp", "kr", "kw", "ky", "kz", "l", "la", "large", "largely", "last", "lately", "later", "latest", "latter", "latterly", "lb", "lc", "least", "length", "less", "lest", "let", "let's", "lets", "li", "like", "liked", "likely", "likewise", "line", "little", "lk", "ll", "long", "longer", "longest", "look", "looking", "looks", "low", "lower", "lr", "ls", "lt", "ltd", "lu", "lv", "ly", "m", "ma", "made", "mainly", "make", "makes", "making", "man", "many", "may", "maybe", "mayn't", "maynt", "mc", "md", "me", "mean", "means", "meantime", "meanwhile", "member", "members", "men", "merely", "mg", "mh", "microsoft", "might", "might've", "mightn't", "mightnt", "mil", "mill", "million", "mine", "minus", "miss", "mk", "ml", "mm", "mn", "mo", "more", "moreover", "most", "mostly", "move", "mp", "mq", "mr", "mrs", "ms", "msie", "mt", "mu", "much", "mug", "must", "must've", "mustn't", "mustnt", "mv", "mw", "mx", "my", "myself", "myse”", "mz", "n", "na", "name", "namely", "nay", "nc", "nd", "ne", "near", "nearly", "necessarily", "necessary", "need", "needed", "needing", "needn't", "neednt", "needs", "neither", "net", "netscape", "never", "neverf", "neverless", "nevertheless", "new", "newer", "newest", "next", "nf", "ng", "ni", "nine", "ninety", "nl", "no", "no-one", "nobody", "non", "none", "nonetheless", "noone", "nor", "normally", "nos", "not", "noted", "nothing", "notwithstanding", "novel", "now", "nowhere", "np", "nr", "nu", "null", "number", "numbers", "nz", "o", "obtain", "obtained", "obviously", "of", "off", "often", "oh", "ok", "okay", "old", "older", "oldest", "om", "omitted", "on", "once", "one", "one's", "ones", "only", "onto", "open", "opened", "opening", "opens", "opposite", "or", "ord", "order", "ordered", "ordering", "orders", "org", "other", "others", "otherwise", "ought", "oughtn't", "oughtnt", "our", "ours", "ourselves", "out", "outside", "over", "overall", "owing", "own", "p", "pa", "page", "pages", "part", "parted", "particular", "particularly", "parting", "parts", "past", "pe", "per", "perhaps", "pf", "pg", "ph", "pk", "pl", "place", "placed", "places", "please", "plus", "pm", "pmid", "pn", "point", "pointed", "pointing", "points", "poorly", "possible", "possibly", "potentially", "pp", "pr", "predominantly", "present", "presented", "presenting", "presents", "presumably", "previously", "primarily", "probably", "problem", "problems", "promptly", "proud", "provided", "provides", "pt", "put", "puts", "pw", "py", "q", "qa", "que", "quickly", "quite", "qv", "r", "ran", "rather", "rd", "re", "readily", "really", "reasonably", "recent", "recently", "ref", "refs", "regarding", "regardless", "regards", "related", "relatively", "research", "reserved", "respectively", "resulted", "resulting", "results", "right", "ring", "ro", "room", "rooms", "round", "ru", "run", "rw", "s", "sa", "said", "same", "saw", "say", "saying", "says", "sb", "sc", "sd", "se", "sec", "second", "secondly", "seconds", "section", "see", "seeing", "seem", "seemed", "seeming", "seems", "seen", "sees", "self", "selves", "sensible", "sent", "serious", "seriously", "seven", "seventy", "several", "sg", "sh", "shall", "shan't", "shant", "she", "she'd", "she'll", "she's", "shed", "shell", "shes", "should", "should've", "shouldn", "shouldn't", "shouldnt", "show", "showed", "showing", "shown", "showns", "shows", "si", "side", "sides", "significant", "significantly", "similar", "similarly", "since", "sincere", "site", "six", "sixty", "sj", "sk", "sl", "slightly", "sm", "small", "smaller", "smallest", "sn", "so", "some", "somebody", "someday", "somehow", "someone", "somethan", "something", "sometime", "sometimes", "somewhat", "somewhere", "soon", "sorry", "specifically", "specified", "specify", "specifying", "sr", "st", "state", "states", "still", "stop", "strongly", "su", "sub", "substantially", "successfully", "such", "sufficiently", "suggest", "sup", "sure", "sv", "sy", "system", "sz", "t", "t's", "take", "taken", "taking", "tc", "td", "tell", "ten", "tends", "test", "text", "tf", "tg", "th", "than", "thank", "thanks", "thanx", "that", "that'll", "that's", "that've", "thatll", "thats", "thatve", "the", "their", "theirs", "them", "themselves", "then", "thence", "there", "there'd", "there'll", "there're", "there's", "there've", "thereafter", "thereby", "thered", "therefore", "therein", "therell", "thereof", "therere", "theres", "thereto", "thereupon", "thereve", "these", "they", "they'd", "they'll", "they're", "they've", "theyd", "theyll", "theyre", "theyve", "thick", "thin", "thing", "things", "think", "thinks", "third", "thirty", "this", "thorough", "thoroughly", "those", "thou", "though", "thoughh", "thought", "thoughts", "thousand", "three", "throug", "through", "throughout", "thru", "thus", "til", "till", "tip", "tis", "tj", "tk", "tm", "tn", "to", "today", "together", "too", "took", "top", "toward", "towards", "tp", "tr", "tried", "tries", "trillion", "truly", "try", "trying", "ts", "tt", "turn", "turned", "turning", "turns", "tv", "tw", "twas", "twelve", "twenty", "twice", "two", "tz", "u", "ua", "ug", "uk", "um", "un", "under", "underneath", "undoing", "unfortunately", "unless", "unlike", "unlikely", "until", "unto", "up", "upon", "ups", "upwards", "us", "use", "used", "useful", "usefully", "usefulness", "uses", "using", "usually", "uucp", "uy", "uz", "v", "va", "value", "various", "vc", "ve", "versus", "very", "vg", "vi", "via", "viz", "vn", "vol", "vols", "vs", "vu", "w", "want", "wanted", "wanting", "wants", "was", "wasn", "wasn't", "wasnt", "way", "ways", "we", "we'd", "we'll", "we're", "we've", "web", "webpage", "website", "wed", "welcome", "well", "wells", "went", "were", "weren", "weren't", "werent", "weve", "wf", "what", "what'd", "what'll", "what's", "what've", "whatever", "whatll", "whats", "whatve", "when", "when'd", "when'll", "when's", "whence", "whenever", "where", "where'd", "where'll", "where's", "whereafter", "whereas", "whereby", "wherein", "wheres", "whereupon", "wherever", "whether", "which", "whichever", "while", "whilst", "whim", "whither", "who", "who'd", "who'll", "who's", "whod", "whoever", "whole", "wholl", "whom", "whomever", "whos", "whose", "why", "why'd", "why'll", "why's", "widely", "width", "will", "willing", "wish", "with", "within", "without", "won", "won't", "wonder", "wont", "words", "work", "worked", "working", "works", "world", "would", "would've", "wouldn", "wouldn't", "wouldnt", "ws", "www", "x", "y", "ye", "year", "years", "yes", "yet", "you", "you'd", "you'll", "you're", "you've", "youd", "youll", "young", "younger", "youngest", "your", "youre", "yours", "yourself", "yourselves", "youve", "yt", "yu", "z", "za", "zero", "zm", "zr" ]
