#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const panelSource = fs.readFileSync(root + '/shell/plugins/panels/monitor/Panel.qml', 'utf8')
const utilSource = fs.readFileSync(root + '/shell/Commons/Util.qml', 'utf8')
const sliderSource = fs.readFileSync(root + '/shell/Ui/PanelSlider.qml', 'utf8')

function block(source, marker) {
  const start = source.indexOf(marker)
  if (start < 0) throw new Error('Missing QML block: ' + marker)
  const open = source.indexOf('{', start)
  const tokens = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\/\/[^\n]*|\/\*[\s\S]*?\*\/|[{}]/g
  tokens.lastIndex = open
  let depth = 0
  for (let token; (token = tokens.exec(source));) {
    if (token[0] === '{') depth++
    if (token[0] === '}' && --depth === 0) return source.slice(open, tokens.lastIndex)
  }
  throw new Error('Unclosed QML block: ' + marker)
}

function functionSource(source, name) {
  const match = source.match(new RegExp('  function ' + name + '\\([^)]*\\)'))
  return match[0].trim() + block(source, match[0])
}

const writeProcess = panelSource.slice(panelSource.indexOf('    id: setBrightnessProc'))
const readProcess = panelSource.slice(panelSource.indexOf('    id: stateProc'))
const exitedSource = '(function(exitCode, exitStatus) ' + block(writeProcess, 'onExited:') + ')'
const runningSource = '(function(running) ' + block(writeProcess, 'onRunningChanged:') + ')'
const readSource = '(function(text) ' + block(readProcess, 'onStreamFinished:') + ')'
const wheelSource = '(function(delta) ' + block(panelSource, 'onWheelMoved:') + ')'
const debounceSource = panelSource.slice(panelSource.indexOf('    id: brightnessDebounce')).match(/onTriggered: ([^\n]+)/)[1]

function panel() {
  const later = []
  const writes = []
  const osds = []
  let running = false
  let runningChanged = () => {}
  let failStart = false
  let refreshes = 0
  const context = vm.createContext({
    Model: requireFromRoot('shell/plugins/panels/monitor/Model.js'),
    Util: vm.runInNewContext('(' + functionSource(utilSource, 'wheelSteps') + ')')
  })
  context.Util = { wheelSteps: context.Util }
  context.root = context
  context.Qt = { callLater: callback => later.push(callback) }
  context.bar = { shell: { summon: (target, payload) => osds.push([target, JSON.parse(payload)]) } }
  context.stateProc = {
    get running() { return this.active || false },
    set running(value) { this.active = value; if (value) refreshes++ }
  }
  context.brightnessDebounce = {
    running: false,
    restart() { this.running = true },
    stop() { this.running = false }
  }
  context.setBrightnessProc = {
    command: [],
    get running() { return running },
    set running(value) {
      if (value && running) throw new Error('Restarted brightness process before it stopped')
      if (value) writes.push(Array.from(this.command))
      running = value && !failStart
      runningChanged(running)
    }
  }
  for (const match of panelSource.matchAll(/^  property (?:int|bool|real|string) (\w+): (.+)$/gm)) {
    context[match[1]] = vm.runInContext(match[2], context)
  }
  for (const name of ['refresh', 'setBrightness', 'finishBrightnessWrite', 'previewBrightness', 'showBrightnessOsd', 'normalizeScale', 'updateDisplays']) {
    vm.runInContext(functionSource(panelSource, name), context)
  }
  const exited = vm.runInContext(exitedSource, context)
  runningChanged = vm.runInContext(runningSource, context)
  const read = vm.runInContext(readSource, context)
  const wheel = vm.runInContext(wheelSource, context)
  const flush = () => {
    for (let count = 0; later.length; count++) {
      if (count > 30) throw new Error('Deferred callbacks did not settle')
      later.shift()()
    }
  }
  const poll = (brightness, monitor = 'DP-1') => {
    read([brightness, 'eDP-1', monitor, 'yes', '', monitor, '1.25', '[]'].join('\n'))
    context.stateProc.running = false
  }
  context.refresh()
  poll('30')
  refreshes = 0
  return {
    root: context, writes, osds, flush, poll,
    get refreshes() { return refreshes },
    targets: () => writes.map(command => command.at(-1)),
    wheel: delta => wheel(delta),
    failStart: () => { failStart = true },
    allowStart: () => { failStart = false },
    exit(code, runningDuringExit = true, status = 0) {
      if (!runningDuringExit) running = false
      exited(code, status)
      running = false
      runningChanged(false)
    },
    debounce() {
      context.brightnessDebounce.running = false
      vm.runInContext(debounceSource, context)
    }
  }
}

function brightness(p, displayed, confirmed, available, description) {
  assertDeepEqual(
    [p.root.brightnessPercent, p.root.confirmedBrightnessPercent, p.root.brightnessAvailable],
    [displayed, confirmed, available], description
  )
}

function brightnessSlider(p) {
  const source = block(panelSource, 'PanelSlider {\n                id: brightnessSlider')
  let enabled = true
  let grabbed = false
  let monitor = p.root.focusedMonitor
  let percent = p.root.brightnessPercent
  const slider = {
    dragging: false, liveValue: percent, value: percent,
    minimum: 1, maximum: 100, range: 99, integer: true, mirrored: false,
    get enabled() { return enabled },
    set enabled(value) { enabled = value; if (!value) grabbed = false },
    moved: vm.runInContext('(function(v) ' + block(source, 'onMoved:') + ')', p.root),
    released: vm.runInContext('(function(v) ' + block(source, 'onReleased:') + ')', p.root)
  }
  p.root.brightnessSlider = slider
  const context = vm.createContext({ root: slider, Qt: { LeftButton: 1 }, track: { width: 99 } })
  Object.defineProperties(context, {
    value: { get() { return slider.value } },
    dragging: { get() { return slider.dragging } },
    liveValue: { set(value) { slider.liveValue = value } }
  })
  vm.runInContext(functionSource(sliderSource, 'valueFromX'), context)
  const pressed = vm.runInContext('(function(mouse) ' + block(sliderSource, 'onPressed:') + ')', context)
  const moved = vm.runInContext('(function(mouse) ' + block(sliderSource, 'onPositionChanged:') + ')', context)
  const released = vm.runInContext('(function(mouse) ' + block(sliderSource, 'onReleased:') + ')', context)
  const valueChanged = sliderSource.match(/onValueChanged: ([^\n]+)/)[1]
  const monitorChanged = source.includes('function onFocusedMonitorChanged()')
    ? vm.runInContext('(' + functionSource(source, 'onFocusedMonitorChanged') + ')', p.root)
    : () => {}
  Object.defineProperty(p.root, 'brightnessPercent', {
    get() { return percent },
    set(value) {
      percent = value
      slider.value = value
      vm.runInContext(valueChanged, context)
    }
  })
  Object.defineProperty(p.root, 'focusedMonitor', {
    get() { return monitor },
    set(value) { if (value !== monitor) { monitor = value; monitorChanged() } }
  })
  return {
    slider,
    press(value) { if (enabled) { grabbed = true; pressed({ button: 1, x: value - 1 }) } },
    move(value) { if (enabled) moved({ x: value - 1 }) },
    release() { if (enabled && grabbed) { grabbed = false; released({ button: 1 }) } }
  }
}

for (const returnToOld of [false, true]) {
  const p = panel()
  const gesture = brightnessSlider(p)
  gesture.press(60)
  assertEqual(gesture.slider.liveValue, 60, 'dragging previews the pressed brightness')
  p.root.refresh()
  p.poll('70', 'DP-2')
  assertEqual(gesture.slider.liveValue, 70, 'a monitor switch replaces the active drag value with the new monitor brightness')
  p.flush()
  gesture.move(90)
  brightness(p, 70, 70, true, 'movement after a monitor switch cannot continue the old drag')
  if (returnToOld) {
    p.root.refresh()
    p.poll('32', 'DP-1')
  }
  gesture.release()
  p.flush()
  assertDeepEqual(p.targets(), [], 'releasing a cancelled drag cannot write to a new monitor or revive it after returning')
  gesture.press(75)
  gesture.release()
  assertDeepEqual(p.writes.at(-1), ['omarchy-brightness-display', '--no-osd', '--monitor', returnToOld ? 'DP-1' : 'DP-2', '75%'], 'a new gesture writes normally after the old drag was cancelled')
}

{
  const p = panel()
  p.root.setBrightness(50)
  p.root.setBrightness(65)
  p.wheel(120)
  p.exit(1)
  p.flush()
  assertDeepEqual(p.targets(), ['50%', '70%'], 'a failed earlier write still submits the latest target')
  brightness(p, 70, 30, true, 'failure preserves the latest preview and the last confirmed value')
  assertEqual(p.osds.length, 0, 'an earlier failure does not show an OSD for the queued target')
  p.exit(0)
  p.flush()
  brightness(p, 70, 70, true, 'the trailing successful write confirms the latest target')
  assertDeepEqual(p.osds, [['omarchy.osd', { icon: 'brightness', value: 70 }]], 'the latest success preserves the pending wheel OSD after an earlier failure')
}

for (const code of [1, 2, 127]) {
  const p = panel()
  p.wheel(120)
  assertEqual(p.osds.length, 0, 'wheel input does not show an unconfirmed OSD')
  p.exit(code)
  p.flush()
  brightness(p, 30, 30, true, 'nonzero exit ' + code + ' rolls back locally, including a dropped busy request')
  assertEqual(p.refreshes, 0, 'failure never starts a read that could hide the slider')
  assertEqual(p.osds.length, 0, 'failure never shows the pending OSD')
  p.root.setBrightness(40)
  p.exit(0)
  p.flush()
  assertEqual(p.osds.length, 0, 'a later keyboard success does not inherit a failed wheel OSD')
}

{
  const p = panel()
  p.wheel(120)
  p.wheel(120)
  p.wheel(120)
  assertDeepEqual(p.targets(), ['35%'], 'wheel bursts coalesce while the helper is running')
  p.exit(0)
  assertDeepEqual(p.targets(), ['35%'], 'the trailing write waits until the process exits')
  p.flush()
  assertDeepEqual(p.targets(), ['35%', '45%'], 'success submits only the newest coalesced target')
  brightness(p, 45, 35, true, 'only the completed write becomes confirmed')
  assertEqual(p.osds.length, 0, 'an intermediate success does not show the OSD')
  p.exit(0)
  p.flush()
  assertDeepEqual(p.osds, [['omarchy.osd', { icon: 'brightness', value: 45 }]], 'the final success shows one OSD for the final target')
  assertEqual(p.refreshes, 0, 'success does not reread brightness')
}

for (const startDuringWrite of [false, true]) {
  for (const read of ['5', 'unavailable', '']) {
    const p = panel()
    if (!startDuringWrite) p.root.refresh()
    p.root.setBrightness(50)
    if (startDuringWrite) p.root.refresh()
    p.exit(0)
    p.flush()
    p.poll(read)
    brightness(p, 50, 50, true, 'stale poll started ' + (startDuringWrite ? 'during' : 'before') + ' a write cannot replace brightness with ' + JSON.stringify(read))
  }
}

for (const code of [0, 1]) {
  const p = panel()
  p.wheel(120)
  p.wheel(120)
  p.root.refresh()
  p.poll('70', 'DP-2')
  brightness(p, 70, 70, true, 'switching monitors adopts the new brightness during an old write')
  assertEqual(p.root.focusedMonitor, 'DP-2', 'brightness and the target monitor switch together')
  p.exit(code)
  p.flush()
  brightness(p, 70, 70, true, 'old monitor completion ' + code + ' cannot confirm or roll back the new monitor')
  assertDeepEqual(p.targets(), ['35%'], 'old queued input is discarded instead of written to the new monitor')
  assertEqual(p.osds.length, 0, 'old monitor completion never shows its OSD on the new monitor')
  p.wheel(120)
  assertDeepEqual(p.writes.at(-1), ['omarchy-brightness-display', '--no-osd', '--monitor', 'DP-2', '75%'], 'new wheel input uses the new monitor brightness and target')
  p.exit(0)
  p.flush()
  brightness(p, 75, 75, true, 'new monitor input can complete after the old write')
}

for (const code of [0, 1]) {
  for (const value of [30, 70]) {
    const p = panel()
    p.wheel(120)
    p.root.refresh()
    p.poll(String(value), 'DP-2')
    p.wheel(120)
    assertDeepEqual(p.targets(), ['35%'], 'new monitor input waits for the old process to stop')
    p.exit(code)
    p.flush()
    assertDeepEqual(p.writes.at(-1), ['omarchy-brightness-display', '--no-osd', '--monitor', 'DP-2', (value + 5) + '%'], 'new monitor intent survives old completion even when its target equals the old write')
    brightness(p, value + 5, value, true, 'old completion cannot confirm the queued new monitor value')
    assertEqual(p.osds.length, 0, 'old completion cannot show the queued new monitor OSD')
    p.exit(0)
    p.flush()
    assertDeepEqual(p.osds, [['omarchy.osd', { icon: 'brightness', value: value + 5 }]], 'new monitor success owns its pending OSD')
  }
}

{
  const p = panel()
  p.root.previewBrightness(60)
  p.root.refresh()
  p.poll('70', 'DP-2')
  brightness(p, 70, 70, true, 'a monitor switch replaces a debounced preview with the new monitor brightness')
  assertEqual(p.root.brightnessDebounce.running, false, 'switching monitors cancels the old preview debounce')
  p.flush()
  assertDeepEqual(p.targets(), [], 'switching during a debounce does not send the old preview to the new monitor')
}

for (const code of [0, 1]) {
  const p = panel()
  p.wheel(120)
  p.wheel(120)
  p.exit(code)
  p.root.refresh()
  p.poll('70', 'DP-2')
  p.flush()
  brightness(p, 70, 70, true, 'switching during a deferred trailing write retains the new monitor snapshot')
  assertDeepEqual(p.targets(), ['35%'], 'a deferred old target is discarded after a monitor switch')
  assertEqual(p.osds.length, 0, 'a deferred old OSD is discarded after a monitor switch')
}

for (const code of [0, 1]) {
  const p = panel()
  p.wheel(120)
  p.root.refresh()
  p.poll('70', 'DP-2')
  p.root.refresh()
  p.poll('32', 'DP-1')
  p.exit(code)
  p.flush()
  brightness(p, 32, 32, true, 'returning to the old monitor still ignores completion from its obsolete snapshot')
  assertDeepEqual(p.targets(), ['35%'], 'returning to a monitor does not create an unsolicited write')
  assertEqual(p.osds.length, 0, 'returning to a monitor does not resurrect its old OSD')
}

for (const read of ['unavailable', '']) {
  const p = panel()
  p.wheel(120)
  p.root.refresh()
  p.poll(read, 'DP-2')
  p.exit(1)
  p.flush()
  brightness(p, 0, 0, false, 'an unavailable new monitor cannot inherit the old monitor brightness or rollback value')
  p.wheel(120)
  assertDeepEqual(p.targets(), ['35%'], 'an unavailable new monitor ignores wheel input')
}

{
  const p = panel()
  p.wheel(120)
  p.root.refresh()
  p.poll('70', 'DP-2')
  p.wheel(120)
  p.exit(0)
  p.flush()
  p.exit(1)
  p.flush()
  brightness(p, 70, 70, true, 'a failed new monitor write rolls back to its own read after an old monitor success')
  assertEqual(p.osds.length, 0, 'a failed new monitor write cannot show an old or new success OSD')
}

{
  const p = panel()
  p.root.setBrightness(50)
  p.root.refresh()
  p.poll('unavailable')
  brightness(p, 50, 30, true, 'a poll delivered during a write cannot hide the brightness slider')
  p.exit(1)
  p.flush()
  brightness(p, 30, 30, true, 'stale polling cannot corrupt failure rollback')
}

for (const startDuringPreview of [false, true]) {
  const p = panel()
  if (!startDuringPreview) p.root.refresh()
  p.root.previewBrightness(60)
  if (startDuringPreview) p.root.refresh()
  p.poll('unavailable')
  brightness(p, 60, 30, true, 'polls cannot replace a pending debounced preview')
  p.debounce()
  assertDeepEqual(p.targets(), ['60%'], 'debounce submits the preserved preview')
  p.root.previewBrightness(80)
  p.exit(0)
  p.flush()
  assertDeepEqual(p.targets(), ['60%', '80%'], 'completion preserves a newer drag preview')
  assertEqual(p.root.brightnessDebounce.running, false, 'submitting a preview stops its debounce timer')
  p.exit(0)
  p.flush()
  p.root.refresh()
  p.poll('42')
  brightness(p, 42, 42, true, 'a fresh idle read updates both displayed and confirmed brightness')
  p.root.refresh()
  p.poll('unavailable')
  brightness(p, 0, 42, false, 'a fresh unavailable read hides the slider without losing the last confirmed value')
}

{
  const p = panel()
  p.root.setBrightness(50)
  p.root.setBrightness(70)
  p.exit(0, false)
  p.exit(0, false)
  p.root.previewBrightness(80)
  p.flush()
  assertDeepEqual(p.targets(), ['50%', '80%'], 'duplicate completion cannot start two writes or capture an obsolete preview')
  brightness(p, 80, 50, true, 'duplicate completion cannot confirm the trailing write')
  p.exit(0)
  p.flush()
  brightness(p, 80, 80, true, 'the trailing write completes after duplicate earlier signals')
}

{
  const p = panel()
  p.wheel(120)
  p.exit(0, false, 1)
  p.flush()
  brightness(p, 30, 30, true, 'a crashed process cannot confirm brightness even with exit code zero')
  assertEqual(p.osds.length, 0, 'a crashed process never shows the pending OSD')
}

{
  const p = panel()
  p.failStart()
  p.wheel(120)
  p.flush()
  brightness(p, 30, 30, true, 'failed process start rolls back through the same completion path')
  assertEqual(p.osds.length, 0, 'failed process start does not show an OSD')
  p.allowStart()
  p.root.setBrightness(60)
  p.exit(0)
  p.flush()
  brightness(p, 60, 60, true, 'normal exit wins over its deferred failed-start check')
}

{
  const p = panel()
  p.failStart()
  p.root.setBrightness(50)
  p.root.setBrightness(70)
  p.allowStart()
  p.flush()
  assertDeepEqual(p.targets(), ['50%', '70%'], 'failed process start preserves a newer target')
  p.exit(0)
  p.flush()
  brightness(p, 70, 70, true, 'the latest target succeeds after an earlier failed start')
}
JS
