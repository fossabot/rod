import nimx/[types, context, image, animation, property_visitor, system_logger]

import json, strutils, tables, times

import rod/[ rod_types, node, component, viewport ]
import rod.tools.serializer
import rod.animation.property_animation

const aeAllCompositionAnimation = "aeAllCompositionAnimation"

type AEMarker* = object
    start*: float
    duration*: float
    name*: string

type AELayer* = ref object of Component
    inPoint*: float
    outPoint*: float
    animScale*: float
    startTime*: float
    duration*: float

type AEComposition* = ref object of Component
    layers*: seq[AELayer]
    markers*: seq[AEMarker]
    duration*: float
    animScale*: float
    buffers: JsonNode
    allCompAnim: Animation

proc setCompositionMarker(c: AEComposition, m: AEMarker): Animation=
    let pStart = m.start / c.duration
    let pEnd = m.duration / c.duration + pStart

    result = newAnimation()
    result.tag = c.node.name & "_" & m.name
    result.numberOfLoops = 1
    result.loopDuration = m.duration
    result.animate prog in pStart..pEnd:
        c.allCompAnim.onAnimate(prog)

proc compositionNamed*(c: AEComposition, marker_name: string, exceptions: seq[string] = nil): Animation

proc applyLayerSettings*(c: AEComposition, cl: AELayer, marker: AEMarker): ComposeMarker=
    let lc = cl.node.componentIfAvailable(AEComposition)
    if not lc.isNil:

        let layerIn = (cl.inPoint - marker.start) / marker.duration
        let layerOut = ((cl.outPoint - marker.start) * cl.animScale) / marker.duration
        if layerIn >= 1.0 or layerOut <= 0.0:
            return #skip layers from other markers

        let pDur = (layerOut - layerIn) * marker.duration / cl.animScale
        var pIn = 0.0 #todo: startTime support
        if layerIn < 0.0:
            pIn += abs(layerIn) / (abs(layerIn) + layerOut)

        var pOut = 1.0
        if layerOut > 1.0:
            pOut /= layerOut

        let prop = lc.compositionNamed(aeAllCompositionAnimation)

        prop.loopDuration *= (pOut - pIn) * cl.animScale
        let oldCompAnimate = prop.onAnimate
        prop.animate prog in pIn..pOut:
            oldCompAnimate(prog)

        result = newComposeMarker(max(0.0, layerIn), min(layerOut, 1.0), prop)

proc compositionNamed*(c: AEComposition, marker_name: string, exceptions: seq[string] = nil): Animation =
    var marker: AEMarker
    for m in c.markers:
        if m.name == marker_name:
            marker = m
            break

    if marker.name.len > 0:
        var prop = c.setCompositionMarker(marker)
        var composeMarkers = newSeq[ComposeMarker]()
        composeMarkers.add(newComposeMarker(0.0, 1.0, prop))

        if not exceptions.isNil:
            for ael in c.layers:
                if ael.node.name notin exceptions:
                    let cm = c.applyLayerSettings(ael, marker)
                    if not cm.isNil:
                        composeMarkers.add(cm)
        else:
            for ael in c.layers:
                let cm = c.applyLayerSettings(ael, marker)
                if not cm.isNil:
                    composeMarkers.add(cm)

        let ca = newCompositAnimation(marker.duration, composeMarkers)
        ca.numberOfLoops = 1
        ca.prepare(epochTime())

        result = newAnimation()
        result.loopDuration = marker.duration
        result.numberOfLoops = 1
        result.onAnimate = proc(p: float)=
            ca.onProgress(p)

proc play*(c: AEComposition, name: string, exceptions: seq[string] = nil): Animation {.discardable.} =
    result = c.compositionNamed(name, exceptions)

    if not c.node.sceneView.isNil:
        c.node.sceneView.addAnimation(result)

proc playAll*(c: AEComposition, exceptions: seq[string] = nil): Animation {.discardable.} =
    result = c.play(aeAllCompositionAnimation)

method deserialize*(c: AEComposition, j: JsonNode, serealizer: Serializer) =
    c.layers = @[]
    if "layers" in j:
        for jln in j["layers"]:
            let ch = c.node.findNode(jln.str)
            if not ch.isNil:
                let ael = ch.componentIfAvailable(AELayer)
                if not ael.isNil:
                    c.layers.add(ael)
            else:
                echo "AEComposition : ", jln.str , " not found in ", c.node.name, " !!!"

    if "markers" in j:
        let markers = j["markers"]
        c.markers = @[]
        for k, jm in markers:
            var m: AEMarker
            m.start = jm["start"].getFNum()
            m.duration = jm["duration"].getFNum()
            m.name = k
            if k == aeAllCompositionAnimation:
                c.duration = m.duration
            c.markers.add(m)

    if "buffers" in j:
        c.buffers = j["buffers"]
        if c.node.animations.isNil:
            c.node.animations = newTable[string, Animation]()

        for m in c.markers:
            c.node.animations[m.name] = c.setCompositionMarker(m)

method serialize*(c: AEComposition, s: Serializer): JsonNode=
    result = newJObject()
    result.add("buffers", c.buffers)

    let markers = newJObject()
    for m in c.markers:
        markers[m.name] = newJObject()
        markers[m.name]["start"] = %m.start
        markers[m.name]["duration"] = %m.duration

    result["markers"] = markers

    let layers = newJArray()
    for l in c.layers:
        layers.add(%l.node.name)
    result["layers"] = layers

method componentNodeWasAddedToSceneView*(c: AEComposition) =
    if c.allCompAnim.isNil:
        c.allCompAnim = newPropertyAnimation(c.node, c.buffers)

method visitProperties*(t: AEComposition, p: var PropertyVisitor) =
    var ll = t.layers.len
    var ml = t.markers.len
    p.visitProperty("markers", ml)
    p.visitProperty("layers",  ll)
    p.visitProperty("duration", t.duration)

    var r = t
    p.visitProperty("AECompos", r)

method deserialize*(c: AELayer, j: JsonNode, serealizer: Serializer) =
    serealizer.deserializeValue(j, "inPoint", c.inPoint)
    serealizer.deserializeValue(j, "outPoint", c.outPoint)
    serealizer.deserializeValue(j, "scale", c.animScale)
    serealizer.deserializeValue(j, "startTime", c.startTime)
    serealizer.deserializeValue(j, "duration", c.duration)

method serialize*(c: AELayer, s: Serializer): JsonNode=
    result = newJObject()
    result.add("inPoint", s.getValue(c.inPoint))
    result.add("outPoint", s.getValue(c.outPoint))
    result.add("scale", s.getValue(c.animScale))
    result.add("startTime", s.getValue(c.startTime))
    result.add("duration", s.getValue(c.duration))

method visitProperties*(t: AELayer, p: var PropertyVisitor) =
    p.visitProperty("inPoint",   t.inPoint)
    p.visitProperty("outPoint",  t.outPoint)
    p.visitProperty("animScale",   t.animScale)
    p.visitProperty("startTime", t.startTime)
    p.visitProperty("duration",  t.duration)

registerComponent(AELayer, "AE support")
registerComponent(AEComposition, "AE support")
