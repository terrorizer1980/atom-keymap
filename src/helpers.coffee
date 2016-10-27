{calculateSpecificity} = require 'clear-cut'
KeyboardLayout = require 'keyboard-layout'

MODIFIERS = new Set(['ctrl', 'alt', 'shift', 'cmd'])
ENDS_IN_MODIFIER_REGEX = /(ctrl|alt|shift|cmd)$/
WHITESPACE_REGEX = /\s+/
KEY_NAMES_BY_KEYBOARD_EVENT_CODE = {
  'Space': 'space',
  'Backspace': 'backspace'
}
NON_CHARACTER_KEY_NAMES_BY_KEYBOARD_EVENT_KEY = {
  'Control': 'ctrl',
  'Meta': 'cmd',
  'ArrowDown': 'down',
  'ArrowUp': 'up',
  'ArrowLeft': 'left',
  'ArrowRight': 'right'
}
MATCH_TYPES = {
  EXACT: 'exact'
  KEYDOWN_EXACT: 'keydownExact'
  PARTIAL: 'partial'
}

isASCIICharacter = (character) ->
  character? and character.length is 1 and character.charCodeAt(0) <= 127

isLatinCharacter = (character) ->
  character? and character.length is 1 and character.charCodeAt(0) <= 0x024F

isUpperCaseCharacter = (character) ->
  character? and character.length is 1 and character.toLowerCase() isnt character

isLowerCaseCharacter = (character) ->
  character? and character.length is 1 and character.toUpperCase() isnt character

usKeymap = null
usCharactersForKeyCode = (code) ->
  usKeymap ?= require('./us-keymap')
  usKeymap[code]

exports.normalizeKeystrokes = (keystrokes) ->
  normalizedKeystrokes = []
  for keystroke in keystrokes.split(WHITESPACE_REGEX)
    if normalizedKeystroke = normalizeKeystroke(keystroke)
      normalizedKeystrokes.push(normalizedKeystroke)
    else
      return false
  normalizedKeystrokes.join(' ')

normalizeKeystroke = (keystroke) ->
  if isKeyup = keystroke.startsWith('^')
    keystroke = keystroke.slice(1)
  keys = parseKeystroke(keystroke)
  return false unless keys

  primaryKey = null
  modifiers = new Set

  for key, i in keys
    if MODIFIERS.has(key)
      modifiers.add(key)
    else
      # only the last key can be a non-modifier
      if i is keys.length - 1
        primaryKey = key
      else
        return false

  if isKeyup
    primaryKey = primaryKey.toLowerCase() if primaryKey?
  else
    modifiers.add('shift') if isUpperCaseCharacter(primaryKey)
    if modifiers.has('shift') and isLowerCaseCharacter(primaryKey)
      primaryKey = primaryKey.toUpperCase()

  keystroke = []
  if not isKeyup or (isKeyup and not primaryKey?)
    keystroke.push('ctrl') if modifiers.has('ctrl')
    keystroke.push('alt') if modifiers.has('alt')
    keystroke.push('shift') if modifiers.has('shift')
    keystroke.push('cmd') if modifiers.has('cmd')
  keystroke.push(primaryKey) if primaryKey?
  keystroke = keystroke.join('-')
  keystroke = "^#{keystroke}" if isKeyup
  keystroke

parseKeystroke = (keystroke) ->
  keys = []
  keyStart = 0
  for character, index in keystroke when character is '-'
    if index > keyStart
      keys.push(keystroke.substring(keyStart, index))
      keyStart = index + 1

      # The keystroke has a trailing - and is invalid
      return false if keyStart is keystroke.length
  keys.push(keystroke.substring(keyStart)) if keyStart < keystroke.length
  keys

exports.keystrokeForKeyboardEvent = (event) ->
  {key, code, ctrlKey, altKey, shiftKey, metaKey} = event

  if key is 'Dead'
    if process.platform isnt 'linux' and characters = KeyboardLayout.getCurrentKeymap()?[event.code]
      if ctrlKey and altKey and shiftKey and characters.withAltGraphShift?
        key = characters.withAltGraphShift
      else if process.platform is 'darwin' and altKey and characters.withAltGraph?
        key = characters.withAltGraph
      else if process.platform is 'win32' and ctrlKey and altKey and characters.withAltGraph?
        key = characters.withAltGraph
      else if shiftKey and characters.withShift?
        key = characters.withShift
      else if characters.unmodified?
        key = characters.unmodified

  if KEY_NAMES_BY_KEYBOARD_EVENT_CODE[code]?
    key = KEY_NAMES_BY_KEYBOARD_EVENT_CODE[code]

  # Work around Chrome bugs on Linux
  if process.platform is 'linux'
    # Fix NumpadDecimal key value being '' with NumLock disabled.
    if code is 'NumpadDecimal' and not event.getModifierState('NumLock')
      key = 'delete'
    # Fix 'Unidentified' key value for '/' key on Brazillian keyboards
    if code is 'IntlRo' and key is 'Unidentified' and ctrlKey
      key = '/'

  isNonCharacterKey = key.length > 1
  if isNonCharacterKey
    key = NON_CHARACTER_KEY_NAMES_BY_KEYBOARD_EVENT_KEY[key] ? key.toLowerCase()
  else
    # Chrome has a bug on Linux: It always reports the U.S. layout value for
    # KeyboardEvent.key when ctrlKey is true. We work around it by consulting
    # the current keymap.
    if process.platform is 'linux' and ctrlKey
      if event.code and (characters = KeyboardLayout.getCurrentKeymap()?[event.code])
        if event.shiftKey and characters.withShift?
          key = characters.withShift
        else if characters.unmodified?
          key = characters.unmodified

    if event.getModifierState('AltGraph')
      # All macOS layouts have an alt-modified character variant for every
      # single key. Therefore, if we always favored the alt variant, it would
      # become impossible to bind `alt-*` to anything. Since `alt-*` bindings
      # are rare and we bind very few by default on macOS, we will only shadow
      # an `alt-*` binding with an alt-modified character variant if it is a
      # basic ASCII character.
      if process.platform is 'darwin' and event.code
        nonAltModifiedKey = nonAltModifiedKeyForKeyboardEvent(event)
        if ctrlKey or metaKey or not isASCIICharacter(key)
          key = nonAltModifiedKey
        else if key isnt nonAltModifiedKey
          altKey = false
      # Windows layouts are more sparing in their use of AltGr-modified
      # characters, and the U.S. layout doesn't have any of them at all. That
      # means that if an AltGr variant character exists for the current
      # keystroke, it likely to be the intended character, and we always
      # interpret it as such rather than favoring a `ctrl-alt-*` binding
      # intepretation.
      else if process.platform is 'win32' and event.code
        nonAltModifiedKey = nonAltModifiedKeyForKeyboardEvent(event)
        if metaKey
          key = nonAltModifiedKey
        else if key isnt nonAltModifiedKey
          ctrlKey = false
          altKey = false
      # Linux has a dedicated `AltGraph` key that is distinct from all other
      # modifiers, including LeftAlt. However, if AltGraph is used in
      # combination with other modifiers, we want to treat it as a modifier and
      # fall back to the non-alt-modified character.
      else if process.platform is 'linux'
        nonAltModifiedKey = nonAltModifiedKeyForKeyboardEvent(event)
        if (ctrlKey or altKey or metaKey) and nonAltModifiedKey
          key = nonAltModifiedKey
          altKey = event.getModifierState('AltGraph')

    # Avoid caps-lock captilizing the key without shift being actually pressed
    unless shiftKey
      key = key.toLowerCase()

  # Use US equivalent character for non-latin characters in keystrokes with modifiers
  # or when using the dvorak-qwertycmd layout and holding down the command key.
  if (key.length is 1 and not isLatinCharacter(key)) or
     (metaKey and KeyboardLayout.getCurrentKeyboardLayout() is 'com.apple.keylayout.DVORAK-QWERTYCMD')
    if characters = usCharactersForKeyCode(event.code)
      if event.shiftKey
        key = characters.withShift
      else
        key = characters.unmodified

  keystroke = ''
  if key is 'ctrl' or ctrlKey
    keystroke += 'ctrl'

  if key is 'alt' or altKey
    keystroke += '-' if keystroke.length > 0
    keystroke += 'alt'

  if key is 'shift' or (shiftKey and (isNonCharacterKey or (isLatinCharacter(key) and isUpperCaseCharacter(key))))
    keystroke += '-' if keystroke
    keystroke += 'shift'

  if key is 'cmd' or metaKey
    keystroke += '-' if keystroke
    keystroke += 'cmd'

  unless MODIFIERS.has(key)
    keystroke += '-' if keystroke
    keystroke += key

  keystroke = normalizeKeystroke("^#{keystroke}") if event.type is 'keyup'
  keystroke

nonAltModifiedKeyForKeyboardEvent = (event) ->
  if event.code and (characters = KeyboardLayout.getCurrentKeymap()?[event.code])
    if event.shiftKey
      characters.withShift
    else
      characters.unmodified

exports.characterForKeyboardEvent = (event) ->
  event.key unless event.ctrlKey or event.metaKey

exports.calculateSpecificity = calculateSpecificity

exports.isBareModifier = (keystroke) -> ENDS_IN_MODIFIER_REGEX.test(keystroke)

exports.keydownEvent = (key, options) ->
  return buildKeyboardEvent(key, 'keydown', options)

exports.keyupEvent = (key, options) ->
  return buildKeyboardEvent(key, 'keyup', options)

buildKeyboardEvent = (key, eventType, {ctrl, shift, alt, cmd, keyCode, target, location}={}) ->
  ctrlKey = ctrl ? false
  altKey = alt ? false
  shiftKey = shift ? false
  metaKey = cmd ? false
  bubbles = true
  cancelable = true

  event = new KeyboardEvent(eventType, {
    key, ctrlKey, altKey, shiftKey, metaKey, bubbles, cancelable
  })

  if target?
    Object.defineProperty(event, 'target', get: -> target)
    Object.defineProperty(event, 'path', get: -> [target])
  event

# bindingKeystrokes and userKeystrokes are arrays of keystrokes
# e.g. ['ctrl-y', 'ctrl-x', '^x']
exports.keystrokesMatch = (bindingKeystrokes, userKeystrokes) ->
  userKeystrokeIndex = -1
  userKeystrokesHasKeydownEvent = false
  matchesNextUserKeystroke = (bindingKeystroke) ->
    while userKeystrokeIndex < userKeystrokes.length - 1
      userKeystrokeIndex += 1
      userKeystroke = userKeystrokes[userKeystrokeIndex]
      isKeydownEvent = not userKeystroke.startsWith('^')
      userKeystrokesHasKeydownEvent = true if isKeydownEvent
      if bindingKeystroke is userKeystroke
        return true
      else if isKeydownEvent
        return false
    null

  isPartialMatch = false
  bindingRemainderContainsOnlyKeyups = true
  bindingKeystrokeIndex = 0
  for bindingKeystroke in bindingKeystrokes
    unless isPartialMatch
      doesMatch = matchesNextUserKeystroke(bindingKeystroke)
      if doesMatch is false
        return false
      else if doesMatch is null
        # Make sure userKeystrokes with only keyup events doesn't match everything
        if userKeystrokesHasKeydownEvent
          isPartialMatch = true
        else
          return false

    if isPartialMatch
      bindingRemainderContainsOnlyKeyups = false unless bindingKeystroke.startsWith('^')

  # Bindings that match the beginning of the user's keystrokes are not a match.
  # e.g. This is not a match. It would have been a match on the previous keystroke:
  # bindingKeystrokes = ['ctrl-tab', '^tab']
  # userKeystrokes    = ['ctrl-tab', '^tab', '^ctrl']
  return false if userKeystrokeIndex < userKeystrokes.length - 1

  if isPartialMatch and bindingRemainderContainsOnlyKeyups
    MATCH_TYPES.KEYDOWN_EXACT
  else if isPartialMatch
    MATCH_TYPES.PARTIAL
  else
    MATCH_TYPES.EXACT
