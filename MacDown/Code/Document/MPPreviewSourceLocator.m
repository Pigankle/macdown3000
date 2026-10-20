//
//  MPPreviewSourceLocator.m
//  MacDown 3000
//
//  Maps a point in the rendered preview back to the Markdown source for
//  "Reveal in Editor" (Issue #627).
//

#import "MPPreviewSourceLocator.h"


// Occurrences of a unit are searched for within this many characters of the
// search position; short units, which occur by chance far more often, use
// the short window.
static const NSUInteger kMPRevealSearchWindow = 50000;
static const NSUInteger kMPRevealShortSearchWindow = 256;
static const NSUInteger kMPRevealShortUnitMaxLength = 3;

// An occurrence is confirmed when a following unit is found within this many
// characters after it. Confirmers are the next few units of at least the
// minimum length, so a tiny unit such as the "s" of "It’s" cannot confirm
// almost anything.
static const NSUInteger kMPRevealConfirmWindow = 2000;
static const NSUInteger kMPRevealConfirmerMinLength = 4;
static const NSUInteger kMPRevealConfirmerCount = 3;
static const NSUInteger kMPRevealConfirmerLookahead = 12;

// At most this many occurrences of the clicked unit are tried per pass.
static const NSUInteger kMPRevealMaxOccurrences = 16;

// HTML comments, script and style blocks, and data: URIs at least this long
// are left out of the searchable source.
static const NSUInteger kMPRevealSkipRangeMinLength = 1000;

// Hoedown's tab stop (expand_tabs).
static const NSUInteger kMPRevealTabStop = 4;

// Characters Hoedown renders without a preceding backslash (char_escape).
static const char *kMPRevealEscapableCharacters =
    "\\`*_{}[]()#+-.!:|&<>^~=\"$";


#pragma mark - Searchable source

/**
 * The searchable forms of the source. N (chars) has backslash escapes
 * dropped, tabs expanded, and skip ranges removed; Nfull (fullChars) is the
 * same with nothing removed. Each map gives the source index of every
 * character, plus the source length at index length.
 */
typedef struct
{
    const unichar *source;
    NSUInteger sourceLength;
    unichar *chars;
    NSUInteger *map;
    NSUInteger *toFull;
    NSUInteger length;
    unichar *fullChars;
    NSUInteger *fullMap;
    NSUInteger fullLength;
} MPRevealSource;

NS_INLINE BOOL MPRevealIsSpace(unichar c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r'
        || c == '\f' || c == '\v';
}

NS_INLINE BOOL MPRevealIsBlankChar(unichar c)
{
    return c == ' ' || c == '\t';
}

NS_INLINE BOOL MPRevealIsNewline(unichar c)
{
    return c == '\n' || c == '\r';
}

// Case-insensitive match of an ASCII lowercase prefix at i.
static BOOL MPRevealHasPrefix(
    const unichar *s, NSUInteger length, NSUInteger i, const char *prefix)
{
    for (NSUInteger k = 0; prefix[k]; k++)
    {
        if (i + k >= length)
            return NO;
        unichar c = s[i + k];
        if (c >= 'A' && c <= 'Z')
            c += 'a' - 'A';
        if (c != (unichar)prefix[k])
            return NO;
    }
    return YES;
}

static NSUInteger MPRevealFindASCII(
    const unichar *s, NSUInteger length, NSUInteger from, const char *pattern)
{
    for (NSUInteger i = from; i < length; i++)
    {
        if (MPRevealHasPrefix(s, length, i, pattern))
            return i;
    }
    return NSNotFound;
}

/**
 * The end of the comment, script or style block, or data: URI starting at
 * i, or NSNotFound. A comment or block without its closing delimiter is not
 * a skip range; unterminated records that, so later openings of the same
 * kind are not searched for again.
 */
static NSUInteger MPRevealSkipRangeEnd(
    const unichar *s, NSUInteger length, NSUInteger i, BOOL unterminated[3])
{
    if (s[i] == 'd' || s[i] == 'D')
    {
        if (!MPRevealHasPrefix(s, length, i, "data:"))
            return NSNotFound;
        NSUInteger j = i + 5;
        while (j < length && !MPRevealIsSpace(s[j]) && s[j] != ')'
               && s[j] != '"' && s[j] != '\'')
            j++;
        return j;
    }
    if (s[i] != '<')
        return NSNotFound;

    if (MPRevealHasPrefix(s, length, i, "<!--"))
    {
        if (unterminated[0])
            return NSNotFound;
        NSUInteger close = MPRevealFindASCII(s, length, i + 4, "-->");
        if (close == NSNotFound)
        {
            unterminated[0] = YES;
            return NSNotFound;
        }
        return close + 3;
    }

    static const char *openings[] = {"<script", "<style"};
    static const char *closings[] = {"</script", "</style"};
    for (int kind = 0; kind < 2; kind++)
    {
        if (!MPRevealHasPrefix(s, length, i, openings[kind]))
            continue;
        NSUInteger after = i + strlen(openings[kind]);
        if (after >= length
            || !(MPRevealIsSpace(s[after]) || s[after] == '>'
                 || s[after] == '/'))
            return NSNotFound;
        if (unterminated[kind + 1])
            return NSNotFound;
        NSUInteger close = MPRevealFindASCII(s, length, after, closings[kind]);
        if (close != NSNotFound)
            close = MPRevealFindASCII(s, length, close, ">");
        if (close == NSNotFound)
        {
            unterminated[kind + 1] = YES;
            return NSNotFound;
        }
        return close + 1;
    }
    return NSNotFound;
}

static NSMutableData *MPRevealSkipRanges(const unichar *s, NSUInteger length)
{
    NSMutableData *ranges = [NSMutableData data];
    BOOL unterminated[3] = {NO, NO, NO};
    NSUInteger i = 0;
    while (i < length)
    {
        NSUInteger end = MPRevealSkipRangeEnd(s, length, i, unterminated);
        if (end != NSNotFound && end - i >= kMPRevealSkipRangeMinLength)
        {
            NSRange range = NSMakeRange(i, end - i);
            [ranges appendBytes:&range length:sizeof(range)];
            i = end;
        }
        else
        {
            i++;
        }
    }
    return ranges;
}

static void MPRevealEmit(
    MPRevealSource *src, unichar c, NSUInteger sourceIndex, BOOL skipped)
{
    if (!skipped)
    {
        src->chars[src->length] = c;
        src->map[src->length] = sourceIndex;
        src->toFull[src->length] = src->fullLength;
        src->length++;
    }
    src->fullChars[src->fullLength] = c;
    src->fullMap[src->fullLength] = sourceIndex;
    src->fullLength++;
}

static void MPRevealSourceInit(MPRevealSource *src, NSString *markdown)
{
    NSUInteger length = markdown.length;
    unichar *s = malloc((length + 1) * sizeof(unichar));
    [markdown getCharacters:s range:NSMakeRange(0, length)];

    NSUInteger tabs = 0;
    for (NSUInteger i = 0; i < length; i++)
    {
        if (s[i] == '\t')
            tabs++;
    }
    NSUInteger capacity = length + tabs * (kMPRevealTabStop - 1) + 1;

    src->source = s;
    src->sourceLength = length;
    src->chars = malloc(capacity * sizeof(unichar));
    src->map = malloc(capacity * sizeof(NSUInteger));
    src->toFull = malloc(capacity * sizeof(NSUInteger));
    src->fullChars = malloc(capacity * sizeof(unichar));
    src->fullMap = malloc(capacity * sizeof(NSUInteger));
    src->length = 0;
    src->fullLength = 0;

    NSData *rangeData = MPRevealSkipRanges(s, length);
    const NSRange *ranges = rangeData.bytes;
    NSUInteger rangeCount = rangeData.length / sizeof(NSRange);
    NSUInteger r = 0;

    // Columns count source characters, before escapes are dropped, and
    // count code points rather than UTF-16 units, as expand_tabs does.
    NSUInteger column = 0;
    for (NSUInteger i = 0; i < length; i++)
    {
        unichar c = s[i];
        if (c == '\\' && i + 1 < length && s[i + 1] < 128
            && strchr(kMPRevealEscapableCharacters, s[i + 1]))
        {
            column++;
            i++;
            c = s[i];
        }
        while (r < rangeCount && i >= NSMaxRange(ranges[r]))
            r++;
        BOOL skipped = (r < rangeCount && i >= ranges[r].location);

        if (MPRevealIsNewline(c))
        {
            MPRevealEmit(src, c, i, skipped);
            column = 0;
        }
        else if (c == '\t')
        {
            do
            {
                MPRevealEmit(src, ' ', i, skipped);
                column++;
            } while (column % kMPRevealTabStop);
        }
        else
        {
            MPRevealEmit(src, c, i, skipped);
            if (!CFStringIsSurrogateLowCharacter(c))
                column++;
        }
    }
    src->map[src->length] = length;
    src->toFull[src->length] = src->fullLength;
    src->fullMap[src->fullLength] = length;
}

static void MPRevealSourceFree(MPRevealSource *src)
{
    free((void *)src->source);
    free(src->chars);
    free(src->map);
    free(src->toFull);
    free(src->fullChars);
    free(src->fullMap);
}

// The first searchable index whose source index is at least sourceIndex.
static NSUInteger MPRevealSearchableIndex(
    const MPRevealSource *src, NSUInteger sourceIndex)
{
    NSUInteger low = 0;
    NSUInteger high = src->length;
    while (low < high)
    {
        NSUInteger mid = low + (high - low) / 2;
        if (src->map[mid] < sourceIndex)
            low = mid + 1;
        else
            high = mid;
    }
    return low;
}


#pragma mark - Units

/**
 * A run of a text node's characters that is expected to appear verbatim in
 * the searchable source: no newline, none of the characters the renderer may
 * have produced from different source text, and no surrounding spaces.
 */
typedef struct
{
    NSUInteger node;
    NSUInteger start;
    const unichar *chars;
    NSUInteger length;
} MPRevealUnit;

NS_INLINE BOOL MPRevealIsSeparator(unichar c)
{
    switch (c)
    {
        case '\n': case '\r':
        // SmartyPants.
        case 0x2019: case 0x2018: case 0x201C: case 0x201D:
        case 0x2013: case 0x2014: case 0x2026:
        case 0x00A9: case 0x00AE: case 0x2122:
        case 0x00BD: case 0x00BC: case 0x00BE:
        // Entities.
        case '&': case '<': case '>': case '"': case '\'':
        // No-break space; zero-width space (MPPreprocessMarkdown).
        case 0x00A0: case 0x200B:
        // Kept literally in code, dropped as an escape elsewhere.
        case '\\':
            return YES;
        default:
            return NO;
    }
}

/** Units of every node, in order; chars points into a shared buffer. */
typedef struct
{
    unichar *buffer;
    MPRevealUnit *units;
    NSUInteger count;
} MPRevealUnits;

static void MPRevealUnitsInit(MPRevealUnits *result, NSArray *texts)
{
    NSUInteger total = 0;
    for (id text in texts)
    {
        if ([text isKindOfClass:[NSString class]])
            total += [text length];
    }
    result->buffer = malloc((total + 1) * sizeof(unichar));
    result->units = malloc((total + 1) * sizeof(MPRevealUnit));
    result->count = 0;

    unichar *chars = result->buffer;
    for (NSUInteger node = 0; node < texts.count; node++)
    {
        NSString *text = texts[node];
        if (![text isKindOfClass:[NSString class]])
            continue;
        NSUInteger length = text.length;
        [text getCharacters:chars range:NSMakeRange(0, length)];
        NSUInteger i = 0;
        while (i < length)
        {
            while (i < length && MPRevealIsSeparator(chars[i]))
                i++;
            NSUInteger start = i;
            while (i < length && !MPRevealIsSeparator(chars[i]))
                i++;
            NSUInteger end = i;
            while (start < end && MPRevealIsBlankChar(chars[start]))
                start++;
            while (end > start && MPRevealIsBlankChar(chars[end - 1]))
                end--;
            if (end > start)
            {
                result->units[result->count++] = (MPRevealUnit){
                    node, start, chars + start, end - start};
            }
        }
        chars += length;
    }
}

static void MPRevealUnitsFree(MPRevealUnits *units)
{
    free(units->buffer);
    free(units->units);
}


#pragma mark - Searching

/** A searchable string, its map to the source, and the units to place. */
typedef struct
{
    const unichar *chars;
    const NSUInteger *map;
    NSUInteger limit;
    const MPRevealUnit *units;
    NSUInteger count;
} MPRevealSearch;

NS_INLINE NSUInteger MPRevealWindow(const MPRevealUnit *unit)
{
    if (unit->length <= kMPRevealShortUnitMaxLength)
        return kMPRevealShortSearchWindow;
    return kMPRevealSearchWindow;
}

NS_INLINE NSUInteger MPRevealAdd(NSUInteger a, NSUInteger b)
{
    return (a > NSUIntegerMax - b) ? NSUIntegerMax : a + b;
}

// The first occurrence of unit starting in [from, maxStart] and ending at or
// before the search limit.
static NSUInteger MPRevealFind(
    const MPRevealSearch *search, const MPRevealUnit *unit,
    NSUInteger from, NSUInteger maxStart)
{
    NSUInteger n = unit->length;
    if (!n || n > search->limit || from > search->limit - n)
        return NSNotFound;
    NSUInteger last = MIN(maxStart, search->limit - n);
    const unichar *chars = search->chars;
    unichar first = unit->chars[0];
    for (NSUInteger i = from; i <= last; i++)
    {
        if (chars[i] != first)
            continue;
        if (!memcmp(chars + i + 1, unit->chars + 1, (n - 1) * sizeof(unichar)))
            return i;
    }
    return NSNotFound;
}

/**
 * Whether an occurrence of unit u ending at end is confirmed by one of the
 * units after it. A unit with no following units is confirmed.
 */
static BOOL MPRevealIsConfirmed(
    const MPRevealSearch *search, NSUInteger u, NSUInteger end)
{
    NSUInteger tried = 0;
    NSUInteger stop = MIN(search->count,
                          u + 1 + kMPRevealConfirmerLookahead);
    for (NSUInteger j = u + 1; j < stop; j++)
    {
        const MPRevealUnit *confirmer = &search->units[j];
        if (confirmer->length < kMPRevealConfirmerMinLength)
            continue;
        NSUInteger maxStart = MPRevealAdd(end, kMPRevealConfirmWindow);
        if (MPRevealFind(search, confirmer, end, maxStart) != NSNotFound)
            return YES;
        if (++tried == kMPRevealConfirmerCount)
            break;
    }
    if (tried)
        return NO;
    if (u + 1 >= search->count)
        return YES;
    NSUInteger maxStart = MPRevealAdd(end, kMPRevealShortSearchWindow);
    return MPRevealFind(search, &search->units[u + 1], end, maxStart)
        != NSNotFound;
}

/**
 * Place units [from, to) in order starting at pointer, and return the end of
 * the last one placed. Each unit takes its first occurrence from the pointer
 * if that is confirmed, and is otherwise skipped. lastPlaced is set to the
 * index of each unit placed.
 */
static NSUInteger MPRevealWalk(
    const MPRevealSearch *search, NSUInteger from, NSUInteger to,
    NSUInteger pointer, NSInteger *lastPlaced)
{
    for (NSUInteger u = from; u < to; u++)
    {
        const MPRevealUnit *unit = &search->units[u];
        NSUInteger maxStart = MPRevealAdd(pointer, MPRevealWindow(unit));
        NSUInteger found = MPRevealFind(search, unit, pointer, maxStart);
        if (found == NSNotFound
            || !MPRevealIsConfirmed(search, u, found + unit->length))
            continue;
        pointer = found + unit->length;
        *lastPlaced = u;
    }
    return pointer;
}

/**
 * Find the clicked unit u from pointer: the first confirmed occurrence in the
 * search window, else the first confirmed occurrence after it. firstInWindow
 * is set to the first occurrence in the window, confirmed or not.
 */
static NSUInteger MPRevealPlaceClicked(
    const MPRevealSearch *search, NSUInteger u, NSUInteger pointer,
    NSUInteger *firstInWindow)
{
    const MPRevealUnit *unit = &search->units[u];
    NSUInteger windowEnd = MPRevealAdd(pointer, MPRevealWindow(unit));
    NSUInteger from = pointer;
    *firstInWindow = NSNotFound;
    for (NSUInteger tries = 0; tries < kMPRevealMaxOccurrences; tries++)
    {
        NSUInteger found = MPRevealFind(search, unit, from, windowEnd);
        if (found == NSNotFound)
            break;
        if (*firstInWindow == NSNotFound)
            *firstInWindow = found;
        if (MPRevealIsConfirmed(search, u, found + unit->length))
            return found;
        from = found + 1;
    }
    from = MPRevealAdd(windowEnd, 1);
    for (NSUInteger tries = 0; tries < kMPRevealMaxOccurrences; tries++)
    {
        NSUInteger found = MPRevealFind(search, unit, from, NSUIntegerMax);
        if (found == NSNotFound)
            break;
        if (MPRevealIsConfirmed(search, u, found + unit->length))
            return found;
        from = found + 1;
    }
    return NSNotFound;
}

// The source index of an end position: the index after the source character
// of the last searchable character, so an end just before a dropped
// character or removed range does not map past the gap.
NS_INLINE NSUInteger MPRevealSourceEnd(const NSUInteger *map, NSUInteger end)
{
    return end ? map[end - 1] + 1 : map[0];
}

NS_INLINE NSUInteger MPRevealSourceOffset(
    const MPRevealSearch *search, NSUInteger found,
    const MPRevealUnit *unit, NSUInteger offset)
{
    if (offset < unit->length)
        return search->map[found + offset];
    return MPRevealSourceEnd(search->map, found + unit->length);
}

/** The clicked node's text, its units, and the clicked offset in it. */
typedef struct
{
    NSString *text;
    NSUInteger offset;
    NSUInteger firstUnit;
    NSUInteger unitCount;
} MPRevealClick;

/**
 * Locate the clicked point. search covers the units to place (the clicked
 * node's among them) and starts at start, which is sourceStart in the
 * source. fullSearch, if given, is the same search in Nfull, used when the
 * clicked unit cannot be found in N; toFull maps N indexes to Nfull.
 */
static NSUInteger MPRevealLocate(
    const MPRevealSearch *search, const MPRevealSearch *fullSearch,
    const NSUInteger *toFull, MPRevealClick click,
    NSUInteger start, NSUInteger sourceStart)
{
    NSInteger lastPlaced = -1;

    // A node with no units (e.g. a table cell containing only "—"): land on
    // its first character if it follows closely, else where the walk ended.
    if (!click.unitCount)
    {
        NSUInteger pointer = MPRevealWalk(
            search, 0, click.firstUnit, start, &lastPlaced);
        NSUInteger pointerSource = lastPlaced < 0 ? sourceStart
            : MPRevealSourceEnd(search->map, pointer);
        NSCharacterSet *spaces =
            [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSRange r = [click.text rangeOfCharacterFromSet:spaces.invertedSet];
        if (r.location == NSNotFound)
            return pointerSource;
        unichar c = [click.text characterAtIndex:r.location];
        MPRevealUnit unit = {0, 0, &c, 1};
        NSUInteger maxStart =
            MPRevealAdd(pointer, kMPRevealShortSearchWindow);
        NSUInteger found = MPRevealFind(search, &unit, pointer, maxStart);
        if (found == NSNotFound)
            return pointerSource;
        return search->map[found];
    }

    // The unit containing the offset; on a separator or trimmed space, the
    // end of the unit before it, else the start of the unit after it.
    NSUInteger u = click.firstUnit;
    NSUInteger offset = 0;
    for (NSUInteger i = click.firstUnit;
         i < click.firstUnit + click.unitCount; i++)
    {
        const MPRevealUnit *unit = &search->units[i];
        if (unit->start > click.offset)
            break;
        u = i;
        offset = MIN(click.offset - unit->start, unit->length);
    }
    const MPRevealUnit *unit = &search->units[u];

    NSUInteger pointer = MPRevealWalk(search, 0, u, start, &lastPlaced);
    NSUInteger pointerSource = lastPlaced < 0 ? sourceStart
        : MPRevealSourceEnd(search->map, pointer);

    NSUInteger firstInWindow = NSNotFound;
    NSUInteger found =
        MPRevealPlaceClicked(search, u, pointer, &firstInWindow);
    if (found != NSNotFound)
        return MPRevealSourceOffset(search, found, unit, offset);

    // The clicked text may be visible text inside a skip range (e.g. a
    // <script> block in a fenced code sample). Redo the walk in Nfull from
    // the last unit placed, so repeated text inside the range still resolves
    // to the clicked occurrence.
    if (fullSearch)
    {
        NSUInteger fullPointer = 0;
        if (lastPlaced >= 0)
            fullPointer = toFull[pointer - 1] + 1;
        else if (pointer)
            fullPointer = toFull[pointer];
        NSInteger fullLastPlaced = lastPlaced;
        fullPointer = MPRevealWalk(fullSearch, (NSUInteger)(lastPlaced + 1),
                                   u, fullPointer, &fullLastPlaced);
        NSUInteger unused = NSNotFound;
        found = MPRevealPlaceClicked(fullSearch, u, fullPointer, &unused);
        if (found != NSNotFound)
            return MPRevealSourceOffset(fullSearch, found, unit, offset);
    }

    if (firstInWindow != NSNotFound)
        return MPRevealSourceOffset(search, firstInWindow, unit, offset);
    return pointerSource;
}

/**
 * Copy the units of nodes in footnote (-1 for the body) into a new array,
 * and fill click with the clicked node's units in it.
 */
static MPRevealUnit *MPRevealSelectUnits(
    const MPRevealUnits *all, NSArray<NSNumber *> *footnotes,
    NSInteger footnote, NSUInteger node, NSUInteger *count,
    MPRevealClick *click)
{
    MPRevealUnit *units = malloc((all->count + 1) * sizeof(MPRevealUnit));
    *count = 0;
    click->firstUnit = 0;
    click->unitCount = 0;
    for (NSUInteger i = 0; i < all->count; i++)
    {
        const MPRevealUnit *unit = &all->units[i];
        NSInteger unitFootnote = -1;
        if (unit->node < footnotes.count)
            unitFootnote = footnotes[unit->node].integerValue;
        if (unitFootnote != footnote && !(footnote < 0 && unitFootnote < 0))
            continue;
        if (unit->node < node)
            click->firstUnit++;
        else if (unit->node == node)
            click->unitCount++;
        units[(*count)++] = *unit;
    }
    return units;
}


#pragma mark - Footnotes

NS_INLINE NSUInteger MPRevealLineEnd(
    const unichar *s, NSUInteger length, NSUInteger i)
{
    while (i < length && !MPRevealIsNewline(s[i]))
        i++;
    return i;
}

NS_INLINE NSUInteger MPRevealNextLine(
    const unichar *s, NSUInteger length, NSUInteger lineEnd)
{
    if (lineEnd >= length)
        return length;
    if (s[lineEnd] == '\r' && lineEnd + 1 < length && s[lineEnd + 1] == '\n')
        return lineEnd + 2;
    return lineEnd + 1;
}

static BOOL MPRevealIsBlank(const unichar *s, NSUInteger from, NSUInteger to)
{
    for (NSUInteger i = from; i < to; i++)
    {
        if (s[i] != ' ' && s[i] != '\t')
            return NO;
    }
    return YES;
}

/**
 * Whether a footnote definition ([^label]: after up to three spaces) starts
 * at line. range is set to its whole extent and content to the part after
 * the colon; both end at the first following non-blank line that is not
 * indented, as in Hoedown's is_footnote.
 */
static NSString *MPRevealFootnoteDefinition(
    const unichar *s, NSUInteger length, NSUInteger line,
    NSRange *range, NSRange *content)
{
    NSUInteger lineEnd = MPRevealLineEnd(s, length, line);
    NSUInteger i = line;
    for (NSUInteger k = 0; k < 3 && i < lineEnd && s[i] == ' '; k++)
        i++;
    if (i + 1 >= lineEnd || s[i] != '[' || s[i + 1] != '^')
        return nil;
    NSUInteger labelStart = i + 2;
    NSUInteger j = labelStart;
    while (j < lineEnd && s[j] != ']')
        j++;
    if (j == labelStart || j + 1 >= lineEnd || s[j + 1] != ':')
        return nil;

    NSUInteger end = MPRevealNextLine(s, length, lineEnd);
    while (end < length)
    {
        NSUInteger e = MPRevealLineEnd(s, length, end);
        if (!MPRevealIsBlank(s, end, e) && s[end] != ' ')
            break;
        end = MPRevealNextLine(s, length, e);
    }
    *range = NSMakeRange(line, end - line);
    *content = NSMakeRange(j + 2, end - (j + 2));
    NSString *label = [NSString stringWithCharacters:s + labelStart
                                              length:j - labelStart];
    return label.lowercaseString;
}

// The end of the backtick code span opening with run backticks at i, or
// NSNotFound. Code spans do not cross a blank line.
static NSUInteger MPRevealCodeSpanEnd(
    const unichar *s, NSUInteger to, NSUInteger i, NSUInteger run)
{
    NSUInteger k = i + run;
    while (k < to)
    {
        if (s[k] == '`')
        {
            NSUInteger closing = 0;
            while (k + closing < to && s[k + closing] == '`')
                closing++;
            if (closing == run)
                return k + closing;
            k += closing;
            continue;
        }
        if (MPRevealIsNewline(s[k]))
        {
            NSUInteger next = MPRevealNextLine(s, to, k);
            if (next >= to
                || MPRevealIsBlank(s, next, MPRevealLineEnd(s, to, next)))
                return NSNotFound;
            k = next;
            continue;
        }
        k++;
    }
    return NSNotFound;
}

/**
 * Append, in order of first occurrence in [from, to), the labels of footnote
 * references that have a definition, skipping fenced code blocks and code
 * spans.
 */
static void MPRevealScanReferences(
    const unichar *s, NSUInteger from, NSUInteger to,
    NSDictionary *definitions, NSMutableArray *labels)
{
    unichar fence = 0;
    NSUInteger fenceLength = 0;
    NSUInteger i = from;
    BOOL lineStart = (i == 0 || MPRevealIsNewline(s[i - 1]));
    while (i < to)
    {
        if (lineStart)
        {
            lineStart = NO;
            NSUInteger lineEnd = MPRevealLineEnd(s, to, i);
            NSUInteger j = i;
            for (NSUInteger k = 0; k < 3 && j < lineEnd && s[j] == ' '; k++)
                j++;
            unichar c = (j < lineEnd) ? s[j] : 0;
            NSUInteger run = 0;
            while ((c == '`' || c == '~') && j + run < lineEnd
                   && s[j + run] == c)
                run++;
            if (fence)
            {
                if (c == fence && run >= fenceLength
                    && MPRevealIsBlank(s, j + run, lineEnd))
                    fence = 0;
                i = lineEnd;
                continue;
            }
            if (run >= 3)
            {
                fence = c;
                fenceLength = run;
                i = lineEnd;
                continue;
            }
        }

        unichar c = s[i];
        if (MPRevealIsNewline(c))
        {
            i++;
            lineStart = YES;
            continue;
        }
        if (c == '`')
        {
            NSUInteger run = 0;
            while (i + run < to && s[i + run] == '`')
                run++;
            NSUInteger end = MPRevealCodeSpanEnd(s, to, i, run);
            i = (end == NSNotFound) ? i + run : end;
            continue;
        }
        if (c == '\\' && i + 1 < to && !MPRevealIsNewline(s[i + 1]))
        {
            i += 2;
            continue;
        }
        if (c == '[' && i + 1 < to && s[i + 1] == '^')
        {
            NSUInteger j = i + 2;
            while (j < to && s[j] != ']' && !MPRevealIsNewline(s[j]))
                j++;
            if (j < to && s[j] == ']' && j > i + 2)
            {
                NSString *label = [NSString stringWithCharacters:s + i + 2
                                                          length:j - i - 2];
                label = label.lowercaseString;
                if (definitions[label] && ![labels containsObject:label])
                    [labels addObject:label];
                i = j + 1;
                continue;
            }
        }
        i++;
    }
}

/**
 * The source range of the content of footnote number index (0-based), as
 * Hoedown numbers them: in order of first reference, counting only
 * references that have a definition. NSNotFound location if there is none.
 */
static NSRange MPRevealFootnoteContent(
    const unichar *s, NSUInteger length, NSUInteger index)
{
    NSMutableDictionary *definitions = [NSMutableDictionary dictionary];
    NSMutableData *definitionRanges = [NSMutableData data];
    NSUInteger line = 0;
    while (line < length)
    {
        NSRange range;
        NSRange content;
        NSString *label =
            MPRevealFootnoteDefinition(s, length, line, &range, &content);
        if (label)
        {
            if (!definitions[label])
                definitions[label] = [NSValue valueWithRange:content];
            [definitionRanges appendBytes:&range length:sizeof(range)];
            line = NSMaxRange(range);
            continue;
        }
        line = MPRevealNextLine(s, length, MPRevealLineEnd(s, length, line));
    }

    // References in the body (everything but the definitions) are numbered
    // first, then those inside each definition, in footnote order.
    NSMutableArray *labels = [NSMutableArray array];
    const NSRange *ranges = definitionRanges.bytes;
    NSUInteger rangeCount = definitionRanges.length / sizeof(NSRange);
    NSUInteger from = 0;
    for (NSUInteger r = 0; r <= rangeCount; r++)
    {
        NSUInteger to = (r < rangeCount) ? ranges[r].location : length;
        MPRevealScanReferences(s, from, to, definitions, labels);
        if (r < rangeCount)
            from = NSMaxRange(ranges[r]);
    }
    for (NSUInteger k = 0; k < labels.count && k <= index; k++)
    {
        NSRange content = [definitions[labels[k]] rangeValue];
        MPRevealScanReferences(s, content.location, NSMaxRange(content),
                               definitions, labels);
    }
    if (index >= labels.count)
        return NSMakeRange(NSNotFound, 0);
    return [definitions[labels[index]] rangeValue];
}


#pragma mark - MPPreviewSourceLocator

@implementation MPPreviewSourceLocator

+ (NSUInteger)sourceLocationForPreviewTexts:(NSArray<NSString *> *)texts
        footnotes:(NSArray<NSNumber *> *)footnotes
        index:(NSUInteger)index offset:(NSUInteger)offset
        inMarkdown:(NSString *)markdown
{
    if (index >= texts.count)
        return 0;

    MPRevealSource source;
    MPRevealSourceInit(&source, markdown);
    MPRevealUnits all;
    MPRevealUnitsInit(&all, texts);

    NSInteger footnote = -1;
    if (index < footnotes.count)
        footnote = MAX(footnotes[index].integerValue, -1);

    MPRevealClick click = {texts[index], offset, 0, 0};
    if (![click.text isKindOfClass:[NSString class]])
        click.text = @"";

    NSUInteger location = NSNotFound;

    // Footnote definitions are rendered at the end of the preview, wherever
    // they are in the source, so a click in one is placed within its
    // definition's source using only that footnote's nodes.
    if (footnote >= 0)
    {
        NSRange content = MPRevealFootnoteContent(
            source.source, source.sourceLength, (NSUInteger)footnote);
        if (content.location != NSNotFound)
        {
            NSUInteger count = 0;
            MPRevealUnit *units = MPRevealSelectUnits(
                &all, footnotes, footnote, index, &count, &click);
            NSUInteger start =
                MPRevealSearchableIndex(&source, content.location);
            NSUInteger end =
                MPRevealSearchableIndex(&source, NSMaxRange(content));
            MPRevealSearch search = {
                source.chars, source.map, end, units, count};
            location = MPRevealLocate(&search, NULL, NULL, click,
                                      start, content.location);
            free(units);
        }
    }

    if (location == NSNotFound)
    {
        NSUInteger count = 0;
        MPRevealUnit *units = MPRevealSelectUnits(
            &all, footnotes, -1, index, &count, &click);
        MPRevealSearch search = {
            source.chars, source.map, source.length, units, count};
        if (footnote >= 0)
        {
            // The footnote's definition was not found: use the end of the
            // body's matched text.
            NSInteger lastPlaced = -1;
            NSUInteger pointer =
                MPRevealWalk(&search, 0, count, 0, &lastPlaced);
            location = (lastPlaced < 0) ? 0
                : MPRevealSourceEnd(source.map, pointer);
        }
        else
        {
            MPRevealSearch fullSearch = {
                source.fullChars, source.fullMap, source.fullLength,
                units, count};
            location = MPRevealLocate(&search, &fullSearch, source.toFull,
                                      click, 0, 0);
        }
        free(units);
    }

    MPRevealUnitsFree(&all);
    MPRevealSourceFree(&source);
    return MIN(location, markdown.length);
}

+ (NSString *)searchableStringForMarkdown:(NSString *)markdown
{
    MPRevealSource source;
    MPRevealSourceInit(&source, markdown);
    NSString *result = [NSString stringWithCharacters:source.chars
                                               length:source.length];
    MPRevealSourceFree(&source);
    return result;
}

@end
