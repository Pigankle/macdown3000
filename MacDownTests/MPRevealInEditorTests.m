//
//  MPRevealInEditorTests.m
//  MacDownTests
//
//  Tests for "Reveal in Editor" (Issue #627): mapping a point in the preview
//  back to the Markdown source (MPPreviewSourceLocator), the preview script
//  (reveal-in-editor.js) through the real renderer, and the MPDocument
//  bridge and context menu.
//

#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <hoedown/document.h>
#import "hoedown_html_patch.h"
#import "MPDocument.h"
#import "MPEditorView.h"
#import "MPPreviewSourceLocator.h"
#import "MPRendererTestHelpers.h"


@interface MPDocument (RevealInEditorTesting)
@property (weak) NSView *editorContainer;
@property (weak) MPEditorView *editor;
@property (weak) WebView *preview;
@property (strong) MPRenderer *renderer;
- (NSArray *)webView:(WebView *)sender
        contextMenuItemsForElement:(NSDictionary *)element
        defaultMenuItems:(NSArray *)defaultMenuItems;
- (void)webView:(WebView *)webView
        decidePolicyForNavigationAction:(NSDictionary *)information
        request:(NSURLRequest *)request frame:(WebFrame *)frame
        decisionListener:(id<WebPolicyDecisionListener>)listener;
@end


#pragma mark - Helpers

static NSString *MPRepeat(NSString *string, NSUInteger minLength)
{
    NSMutableString *result = [NSMutableString string];
    while (result.length < minLength)
        [result appendString:string];
    return result;
}

// Location of the nth (0-based) occurrence of string in text.
static NSUInteger MPNth(NSString *text, NSString *string, NSUInteger nth)
{
    NSUInteger from = 0;
    for (NSUInteger i = 0; ; i++)
    {
        NSRange r = [text rangeOfString:string options:NSLiteralSearch
                                  range:NSMakeRange(from, text.length - from)];
        if (r.location == NSNotFound || i == nth)
            return r.location;
        from = NSMaxRange(r);
    }
}

static NSUInteger MPLocate(
    NSArray *texts, NSArray *footnotes, NSUInteger index, NSUInteger offset,
    NSString *markdown)
{
    return [MPPreviewSourceLocator sourceLocationForPreviewTexts:texts
        footnotes:footnotes index:index offset:offset inMarkdown:markdown];
}


/**
 * Records every navigation the preview requests. Custom schemes and links
 * are ignored; only the initial page load is allowed.
 */
@interface MPRevealPolicyRecorder : NSObject <WebPolicyDelegate>
@property (strong) NSMutableArray<NSURL *> *requests;
@end

@implementation MPRevealPolicyRecorder

- (instancetype)init
{
    self = [super init];
    if (self)
        _requests = [NSMutableArray array];
    return self;
}

- (void)webView:(WebView *)webView
        decidePolicyForNavigationAction:(NSDictionary *)information
        request:(NSURLRequest *)request frame:(WebFrame *)frame
        decisionListener:(id<WebPolicyDecisionListener>)listener
{
    NSURL *url = request.URL;
    NSInteger type = [information[WebActionNavigationTypeKey] integerValue];
    if (type == WebNavigationTypeOther
        && (url.isFileURL || [url.scheme isEqualToString:@"about"]))
    {
        [listener use];
        return;
    }
    [self.requests addObject:url];
    [listener ignore];
}

- (NSArray<NSURL *> *)requestsWithScheme:(NSString *)scheme
{
    NSPredicate *predicate = [NSPredicate predicateWithBlock:
        ^BOOL(NSURL *url, NSDictionary *bindings) {
            return [url.scheme isEqualToString:scheme];
        }];
    return [self.requests filteredArrayUsingPredicate:predicate];
}

@end


/** Records whether the document used or ignored a navigation. */
@interface MPRevealDecisionListener : NSObject <WebPolicyDecisionListener>
@property BOOL ignored;
@property BOOL used;
@end

@implementation MPRevealDecisionListener
- (void)use
{
    self.used = YES;
}
- (void)download
{
}
- (void)ignore
{
    self.ignored = YES;
}
@end


/** A real renderer and an offscreen preview showing its output. */
@interface MPRevealPreview : NSObject
@property (strong) MPRenderer *renderer;
@property (strong) MPMockRendererDelegate *delegate;
@property (strong) MPMockRendererDataSource *dataSource;
@property (strong) NSWindow *window;
@property (strong) WebView *webView;
@property (strong) MPRevealPolicyRecorder *recorder;
@property (copy) NSString *markdown;
@end

@implementation MPRevealPreview

- (instancetype)initWithMarkdown:(NSString *)markdown
                       configure:(void (^)(MPRevealPreview *))configure
{
    self = [super init];
    if (!self)
        return nil;

    _markdown = [markdown copy];
    _dataSource = [[MPMockRendererDataSource alloc] init];
    _dataSource.markdown = markdown;
    _delegate = [[MPMockRendererDelegate alloc] init];
    // App defaults: tables, fenced code and footnotes.
    _delegate.extensions = HOEDOWN_EXT_TABLES | HOEDOWN_EXT_FENCED_CODE
        | HOEDOWN_EXT_FOOTNOTES;
    _renderer = [[MPRenderer alloc] init];
    _renderer.dataSource = _dataSource;
    _renderer.delegate = _delegate;
    if (configure)
        configure(self);

    [_renderer parseMarkdown:markdown];
    [_renderer render];

    NSRect frame = NSMakeRect(0, 0, 800, 600);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.releasedWhenClosed = NO;
    _webView = [[WebView alloc] initWithFrame:frame];
    _window.contentView = _webView;
    _recorder = [[MPRevealPolicyRecorder alloc] init];
    _webView.policyDelegate = _recorder;

    NSURL *base = [NSURL fileURLWithPath:NSTemporaryDirectory()
                             isDirectory:YES];
    [_webView.mainFrame loadHTMLString:_delegate.lastHTML baseURL:base];
    return self;
}

- (JSContext *)context
{
    return self.webView.mainFrame.javaScriptContext;
}

- (JSValue *)evaluate:(NSString *)script
{
    return [self.context evaluateScript:script];
}

- (BOOL)waitFor:(NSString *)condition
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while (deadline.timeIntervalSinceNow > 0)
    {
        if (!self.webView.isLoading && [[self evaluate:condition] toBool])
            return YES;
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return NO;
}

- (BOOL)waitUntilReady
{
    return [self waitFor:
        @"document.readyState === 'complete'"
        @" && typeof window.macdownRevealCollect === 'function'"];
}

- (void)spinFor:(NSTimeInterval)seconds
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0)
    {
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static NSString *MPJSString(NSString *string)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[string]
                                                   options:0 error:NULL];
    NSString *array = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];
    return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

/**
 * Record the point at the start of marker in the nth text node (in the
 * whole body, excluded or not) containing it. Returns whether found.
 */
- (BOOL)setPointAtMarker:(NSString *)marker nth:(NSUInteger)nth
{
    NSString *script = [NSString stringWithFormat:
        @"(function (marker, nth) {"
        @"  var walker = document.createTreeWalker("
        @"      document.body, NodeFilter.SHOW_TEXT, null, false);"
        @"  for (var n = walker.nextNode(); n; n = walker.nextNode()) {"
        @"    var i = n.nodeValue.indexOf(marker);"
        @"    if (i >= 0 && nth-- === 0) {"
        @"      window.macdownRevealPoint = {node: n, offset: i};"
        @"      return true;"
        @"    }"
        @"  }"
        @"  return false;"
        @"})(%@, %lu)", MPJSString(marker), (unsigned long)nth];
    return [[self evaluate:script] toBool];
}

- (NSDictionary *)collect
{
    return [[self evaluate:@"window.macdownRevealCollect()"] toDictionary];
}

- (NSUInteger)locateCollected
{
    NSDictionary *info = [self collect];
    return MPLocate(info[@"texts"], info[@"footnotes"],
                    [info[@"index"] unsignedIntegerValue],
                    [info[@"offset"] unsignedIntegerValue], self.markdown);
}

// Dispatch a synthesised mouse event at the centre of the element selected
// by selector.
- (void)dispatch:(NSString *)type at:(NSString *)selector alt:(BOOL)alt
{
    NSString *script = [NSString stringWithFormat:
        @"(function () {"
        @"  var el = document.querySelector(%@);"
        @"  var rect = el.getBoundingClientRect();"
        @"  var x = rect.left + rect.width / 2;"
        @"  var y = rect.top + rect.height / 2;"
        @"  var event = document.createEvent('MouseEvents');"
        @"  event.initMouseEvent(%@, true, true, window, 1, x, y, x, y,"
        @"      false, %@, false, false, 0, null);"
        @"  el.dispatchEvent(event);"
        @"})()", MPJSString(selector), MPJSString(type),
        alt ? @"true" : @"false"];
    [self evaluate:script];
}

- (void)dealloc
{
    _webView.policyDelegate = nil;
    [_window close];
}

@end


#pragma mark - Tests

@interface MPRevealInEditorTests : XCTestCase
@end


@implementation MPRevealInEditorTests

#pragma mark - Matching

/**
 * Test that a click mid-word in the second of two plain paragraphs maps to
 * the same offset in the source.
 */
- (void)testPlainParagraphsClickMidWord
{
    NSString *md = @"First paragraph here.\n\nSecond paragraph with words.";
    NSArray *texts = @[@"First paragraph here.",
                       @"Second paragraph with words."];
    NSUInteger offset = [texts[1] rangeOfString:@"with"].location + 2;
    XCTAssertEqual(MPLocate(texts, nil, 1, offset, md),
                   [md rangeOfString:@"with"].location + 2,
                   @"Click should map to the same offset in the source");
}

/**
 * Test that repeated cells in a single-line raw-HTML table resolve to the
 * clicked cell. The walk must advance past earlier cells; fails if it
 * restarts at the top or never advances (the click lands in the first cell).
 */
- (void)testRepeatedCellsInSingleLineTableResolveToClickedCell
{
    NSString *md = @"Intro text.\n\n<table><tr><td>Lea County</td>"
        @"<td>Oil</td></tr><tr><td>Lea County</td><td>Gas</td></tr><tr>"
        @"<td>Lea County</td><td>Water</td></tr></table>\n\nAfter.";
    NSArray *texts = @[@"Intro text.", @"Lea County", @"Oil", @"Lea County",
                       @"Gas", @"Lea County", @"Water", @"After."];
    XCTAssertEqual(MPLocate(texts, nil, 5, 4, md),
                   MPNth(md, @"Lea County", 2) + 4,
                   @"Third cell should resolve to the third occurrence");
    XCTAssertEqual(MPLocate(texts, nil, 3, 4, md),
                   MPNth(md, @"Lea County", 1) + 4,
                   @"Second cell should resolve to the second occurrence");
}

/**
 * Test that text split into several nodes by inline formatting maps back
 * into and after the formatted span.
 */
- (void)testInlineFormattingSplit
{
    NSString *md = @"Some **bold** text here.";
    NSArray *texts = @[@"Some ", @"bold", @" text here."];
    XCTAssertEqual(MPLocate(texts, nil, 2, 6, md),
                   [md rangeOfString:@"here"].location,
                   @"Text after the bold span should map past the markup");
    XCTAssertEqual(MPLocate(texts, nil, 1, 1, md),
                   [md rangeOfString:@"bold"].location + 1,
                   @"Text inside the bold span should map inside it");
}

/**
 * Test that a soft line break in a list item, which drops the source's
 * continuation indent, still maps to the clicked word.
 */
- (void)testSoftLineBreakInIndentedListItem
{
    NSString *md = @"- foo item\n  bar item";
    NSArray *texts = @[@"foo item\nbar item"];
    NSUInteger offset = [texts[0] rangeOfString:@"bar"].location + 1;
    XCTAssertEqual(MPLocate(texts, nil, 0, offset, md),
                   [md rangeOfString:@"bar"].location + 1,
                   @"Second line should map past the continuation indent");
}

/**
 * Test that SmartyPants curly apostrophes do not prevent a match. Fails
 * without splitting units on ’: the whole run is never found.
 */
- (void)testSmartyPantsApostrophes
{
    NSString *md = @"It's Lea County's plan";
    NSArray *texts = @[@"It’s Lea County’s plan"];
    NSUInteger offset = [texts[0] rangeOfString:@"plan"].location;
    XCTAssertEqual(MPLocate(texts, nil, 0, offset, md),
                   [md rangeOfString:@"plan"].location,
                   @"Text after a curly apostrophe should be found");
}

/**
 * Test that an entity in a raw-HTML cell does not misplace the walk. Fails
 * without splitting on &: "Oil & Gas" only matches the prose.
 */
- (void)testEntityInRawHTMLCell
{
    NSString *md = @"<table><tr><td>Oil &amp; Gas</td><td>Lea County</td>"
        @"<td>Lea County</td></tr></table>\n\n"
        @"Oil & Gas leases in Lea County.";
    NSArray *texts = @[@"Oil & Gas", @"Lea County", @"Lea County",
                       @"Oil & Gas leases in Lea County."];
    XCTAssertEqual(MPLocate(texts, nil, 2, 0, md),
                   MPNth(md, @"Lea County", 1),
                   @"Second cell should resolve to the second occurrence");
    XCTAssertEqual(MPLocate(texts, nil, 0, 6, md),
                   MPNth(md, @"Gas", 0),
                   @"Text after the entity should resolve to the table cell");
}

/**
 * Test that short units are only searched for in the short window. The
 * generated footnote number "1" must not be matched in "2019" more than 256
 * characters on; fails if short units use the long window.
 */
- (void)testShortUnitsUseShortWindow
{
    NSString *filler = MPRepeat(@"Filler text without any digits. ", 300);
    NSString *md = [NSString stringWithFormat:
        @"Intro with a note[^a] and more words here.\n\n%@\n\n"
        @"2019 and more words here.\n\n[^a]: The note.", filler];
    NSArray *texts = @[@"Intro with a note", @"1",
                       @" and more words here.", filler,
                       @"2019 and more words here."];
    NSUInteger offset = [texts[2] rangeOfString:@"more"].location;
    XCTAssertEqual(MPLocate(texts, nil, 2, offset, md),
                   MPNth(md, @"more", 0),
                   @"Click should resolve to the first paragraph");
}

/**
 * Test that unconfirmed generated text does not move the search position.
 * A generated "JSON" label must not be matched to a later mention; fails
 * without confirmation.
 */
- (void)testUnconfirmedGeneratedTextDoesNotMovePointer
{
    NSString *filler = MPRepeat(@"Filler sentence goes here. ", 10000);
    NSString *md = [NSString stringWithFormat:
        @"```json\n{\"key\": \"value\"}\n```\n\n"
        @"Middle paragraph to click.\n\n%@\n\n"
        @"The JSON format is described here.", filler];
    NSArray *texts = @[@"JSON", @"{\"key\": \"value\"}\n",
                       @"Middle paragraph to click.", filler,
                       @"The JSON format is described here."];
    XCTAssertEqual(MPLocate(texts, nil, 2, 7, md),
                   [md rangeOfString:@"paragraph to click"].location,
                   @"Click should resolve to the middle paragraph");
}

/**
 * Test that an orphan TOC entry before the headings is not matched to a
 * later heading. Fails without confirmation.
 */
- (void)testOrphanTOCEntryIsNotMatched
{
    NSString *md = @"## Abstract\n\nabstract body\n\n# Introduction\n\n"
        @"intro body";
    NSArray *texts = @[@"Introduction", @"Abstract", @"abstract body",
                       @"Introduction", @"intro body"];
    XCTAssertEqual(MPLocate(texts, nil, 2, 9, md),
                   [md rangeOfString:@"abstract body"].location + 9,
                   @"Click should resolve to the abstract body");
}

/**
 * Test that the clicked unit is matched to its confirmed occurrence when an
 * earlier, unconfirmed duplicate sits between the search position and the
 * clicked occurrence. Fails without iterating occurrences in step 1.
 */
- (void)testClickedUnitIteratesToConfirmedOccurrence
{
    NSString *spans = MPRepeat(@"<span></span>", 3000);
    NSString *md = [NSString stringWithFormat:
        @"Lea County\n\n%@\n\nLea County\n\nafter", spans];
    NSArray *texts = @[@"Lea County", @"Lea County", @"after"];
    XCTAssertEqual(MPLocate(texts, nil, 1, 4, md),
                   MPNth(md, @"Lea County", 1) + 4,
                   @"Click should resolve to the second occurrence");
}

/**
 * Test that the walk does not skip ahead to a later confirmed duplicate of
 * an unconfirmed unit. Fails if it does: the search position passes the
 * clicked text.
 */
- (void)testWalkDoesNotIterateToLaterDuplicates
{
    NSString *spans = MPRepeat(@"<span></span>", 2500);
    NSString *md = [NSString stringWithFormat:
        @"## Lea County\n\n%@\n\nSummary of findings\n\n"
        @"<table><tr><td>Lea County</td><td>more text here</td></tr>"
        @"</table>", spans];
    NSArray *texts = @[@"Lea County", @"Summary of findings",
                       @"Lea County", @"more text here"];
    XCTAssertEqual(MPLocate(texts, nil, 1, 11, md),
                   [md rangeOfString:@"findings"].location,
                   @"Click should resolve to the summary paragraph");
}

/**
 * Test that backslash escapes are normalised, with the offset accounting for
 * the dropped backslash. Fails without escape normalisation.
 */
- (void)testBackslashEscapes
{
    NSString *md = @"Intro.\n\nBonus of \\$500 per acre in Lea County wells.";
    NSArray *texts = @[@"Intro.",
                       @"Bonus of $500 per acre in Lea County wells."];
    NSUInteger offset = [texts[1] rangeOfString:@"wells"].location;
    XCTAssertEqual(MPLocate(texts, nil, 1, offset, md),
                   [md rangeOfString:@"wells"].location,
                   @"Text after an escape should map past the backslash");
    offset = [texts[1] rangeOfString:@"500"].location;
    XCTAssertEqual(MPLocate(texts, nil, 1, offset, md),
                   [md rangeOfString:@"500"].location,
                   @"Escaped text should map past the backslash");
}

/**
 * Test that tabs are expanded to Hoedown's tab stops. Fails without tab
 * expansion.
 */
- (void)testTabsExpandedAsHoedownDoes
{
    NSString *md = @"```\nLea County\t2019\tOil\n```";
    NSArray *texts = @[@"Lea County  2019    Oil\n"];
    NSUInteger offset = [texts[0] rangeOfString:@"Oil"].location;
    XCTAssertEqual(MPLocate(texts, nil, 0, offset, md),
                   [md rangeOfString:@"Oil"].location,
                   @"Text after expanded tabs should map past the tabs");
}

/**
 * Test that tab columns count the backslash of an escape and count an
 * emoji once.
 */
- (void)testTabColumnsCountSourceCodePoints
{
    NSString *md = @"\U0001F600 a\\*b\tOil rights here";
    NSArray *texts = @[@"\U0001F600 a*b  Oil rights here"];
    NSUInteger offset = [texts[0] rangeOfString:@"Oil"].location;
    XCTAssertEqual(MPLocate(texts, nil, 0, offset, md),
                   [md rangeOfString:@"Oil"].location,
                   @"Text after the tab should map past the tab");
}

/**
 * Test that a long HTML comment is removed from the searchable source and
 * that locations after it map back to the source. Fails if the index map
 * does not account for the removed comment.
 */
- (void)testSkipRangeMapping
{
    NSString *comment = [NSString stringWithFormat:@"<!-- %@ -->",
                         MPRepeat(@"x", 1500)];
    NSString *md = [comment stringByAppendingString:
                    @"\n\nParagraph after comment."];
    NSArray *texts = @[@"Paragraph after comment."];
    XCTAssertEqual(MPLocate(texts, nil, 0, 16, md),
                   [md rangeOfString:@"comment."].location,
                   @"Text after the comment should map to the source");
    XCTAssertLessThan(
        [MPPreviewSourceLocator searchableStringForMarkdown:md].length,
        md.length - 1000, @"The comment is a skip range");
}

/**
 * Test that visible text inside a skip range is found through Nfull, and
 * repeated text there resolves to the clicked occurrence. Fails without
 * step 3, or if step 3 searches Nfull from the search position without
 * re-walking.
 */
- (void)testVisibleTextInsideSkipRange
{
    NSMutableString *body = [NSMutableString string];
    [body appendString:@"<script>\nbtn.addEventListener('click', a);\n"];
    for (NSUInteger i = 1; i <= 60; i++)
        [body appendFormat:@"// filler line number %lu\n", (unsigned long)i];
    [body appendString:@"link.addEventListener('click', b);\n</script>\n"];
    XCTAssertGreaterThan(body.length, 1000u,
                         @"Precondition: the script block is a skip range");
    NSString *md = [NSString stringWithFormat:
        @"Intro paragraph.\n\n```html\n%@```\n", body];
    NSArray *texts = @[@"Intro paragraph.", body];
    NSUInteger offset = MPNth(body, @"click", 1) + 2;
    XCTAssertEqual(MPLocate(texts, nil, 1, offset, md),
                   MPNth(md, @"click", 1) + 2,
                   @"Click should resolve to the second occurrence");
}

/**
 * Test that an unterminated comment or script block is not removed from
 * the searchable source.
 */
- (void)testUnterminatedCommentIsNotASkipRange
{
    NSString *md = [@"Before <!-- " stringByAppendingString:
                    MPRepeat(@"y", 2000)];
    XCTAssertEqualObjects(
        [MPPreviewSourceLocator searchableStringForMarkdown:md], md,
        @"An unterminated comment should be left in place");
    NSString *script = [@"Before <script> " stringByAppendingString:
                        MPRepeat(@"y", 2000)];
    XCTAssertEqualObjects(
        [MPPreviewSourceLocator searchableStringForMarkdown:script], script,
        @"An unterminated script block should be left in place");
}

/**
 * Test that a click on the separator after a unit that ends just before a
 * dropped backslash maps to the index right after the unit, not past the
 * gap.
 */
- (void)testEndMappingBeforeDroppedBackslash
{
    NSString *md = @"Lea County\\\"quoted\\\" text";
    NSArray *texts = @[@"Lea County\"quoted\" text"];
    XCTAssertEqual(MPLocate(texts, nil, 0, 10, md), 10u,
                   @"Click should map to just after the unit");
}

/**
 * Test that confirmers shorter than 4 characters are not used when longer
 * ones exist. Fails if they are: the "s" of "It’s" confirms the later
 * "Notes".
 */
- (void)testTinyConfirmersAreNotUsed
{
    NSString *md = @"It's *worth reading carefully*.\n\n"
        @"Notes: this has s here.";
    NSArray *texts = @[@"Notes", @"It’s ", @"worth reading carefully",
                       @"."];
    XCTAssertEqual(MPLocate(texts, nil, 2, 6, md),
                   [md rangeOfString:@"reading"].location,
                   @"Click should resolve to the emphasised text");
}

/**
 * Test that repeated lines in a long code block resolve to the clicked
 * line. Confirmation looks past the clicked node; under next-node-only
 * confirmation every line is unconfirmed and the first "return x;" wins.
 */
- (void)testLongCodeBlockRepeatedLines
{
    NSMutableString *code = [NSMutableString string];
    for (NSUInteger i = 1; i <= 30; i++)
        [code appendFormat:@"// %lu\nreturn x;\n", (unsigned long)i];
    NSString *md = [NSString stringWithFormat:@"```\n%@```\n", code];
    NSArray *texts = @[code, @"Generated label not in source"];
    NSUInteger offset = MPNth(code, @"return x;", 2) + 3;
    XCTAssertEqual(MPLocate(texts, nil, 0, offset, md),
                   MPNth(md, @"return x;", 2) + 3,
                   @"Click should resolve to the third repeated line");
}

/**
 * Test that a footnote defined mid-document, which the preview shows at the
 * end, maps to its definition. Fails without footnote handling: lands at
 * the end of "More body text".
 */
- (void)testFootnoteDefinedMidDocument
{
    NSString *md = @"Intro text[^1].\n\n[^1]: The lease expired in 2019."
        @"\n\nMore body text.";
    NSArray *texts = @[@"Intro text", @".", @"More body text.",
                       @"The lease expired in 2019. "];
    NSArray *footnotes = @[@-1, @-1, @-1, @0];
    XCTAssertEqual(MPLocate(texts, footnotes, 3, 10, md),
                   [md rangeOfString:@"expired"].location,
                   @"Click should resolve to the footnote definition");
}

/**
 * Test that footnotes are numbered in reference order, not definition
 * order, so identical footnote texts resolve to their own definitions.
 */
- (void)testFootnotesNumberedInReferenceOrder
{
    NSString *md = @"First[^a] then[^b].\n\n[^b]: Same note text.\n\n"
        @"[^a]: Same note text.";
    NSArray *texts = @[@"First", @" then", @".",
                       @"Same note text. ", @"Same note text. "];
    NSArray *footnotes = @[@-1, @-1, @-1, @0, @1];
    XCTAssertEqual(MPLocate(texts, footnotes, 3, 5, md),
                   MPNth(md, @"note", 1),
                   @"Footnote 1 should resolve to the [^a] definition");
    XCTAssertEqual(MPLocate(texts, footnotes, 4, 5, md),
                   MPNth(md, @"note", 0),
                   @"Footnote 2 should resolve to the [^b] definition");
}

/**
 * Test that undefined footnote references are not numbered.
 */
- (void)testUndefinedFootnoteReferenceIsNotNumbered
{
    NSString *md = @"Smith reports this[^x] and later[^a].\n\n"
        @"[^a]: Lease records, 2019.";
    NSArray *texts = @[@"Smith reports this[^x] and later", @".",
                       @"Lease records, 2019. "];
    NSArray *footnotes = @[@-1, @-1, @0];
    XCTAssertEqual(MPLocate(texts, footnotes, 2, 6, md),
                   [md rangeOfString:@"records"].location,
                   @"Footnote 1 should resolve to the [^a] definition");
}

/**
 * Test that footnote labels match case-insensitively, so [^A] is footnote
 * a.
 */
- (void)testFootnoteLabelsAreCaseInsensitive
{
    NSString *md = @"Earlier[^A] mention, then[^b] and[^a].\n\n"
        @"[^b]: Bravo records.\n\n[^a]: Lease records, 2019.";
    NSArray *texts = @[@"Earlier", @" mention, then", @" and", @".",
                       @"Lease records, 2019. ",
                       @"Bravo records. "];
    NSArray *footnotes = @[@-1, @-1, @-1, @-1, @0, @1];
    XCTAssertEqual(MPLocate(texts, footnotes, 4, 6, md),
                   MPNth(md, @"records", 1),
                   @"Footnote 1 should resolve to the [^a] definition");
}

/**
 * Test that a footnote reference inside a code span is literal text and is
 * not numbered.
 */
- (void)testFootnoteReferenceInCodeSpanIsNotNumbered
{
    NSString *md = @"Code `[^b]` first, then real[^a] and[^b].\n\n"
        @"[^b]: Shared note text.\n\n[^a]: Shared note text.";
    NSArray *texts = @[@"Code ", @"[^b]", @" first, then real", @" and",
                       @".", @"Shared note text. ",
                       @"Shared note text. "];
    NSArray *footnotes = @[@-1, @-1, @-1, @-1, @-1, @0, @1];
    XCTAssertEqual(MPLocate(texts, footnotes, 5, 7, md),
                   MPNth(md, @"note", 1),
                   @"Footnote 1 should resolve to the [^a] definition");
}

/**
 * Test that a cell with no searchable units (only a separator character)
 * resolves to that character.
 */
- (void)testZeroUnitCell
{
    NSString *md = @"<table><tr><td>Lea County</td><td>—</td>"
        @"<td>12</td></tr></table>";
    NSArray *texts = @[@"Lea County", @"—", @"12"];
    XCTAssertEqual(MPLocate(texts, nil, 1, 0, md),
                   [md rangeOfString:@"—"].location,
                   @"Click should resolve to the dash cell");
}

/**
 * Test that a long data: URI is skipped. Fails without skip ranges: the walk
 * strands behind the image data and step 2 returns the first cell.
 */
- (void)testDataURIIsSkipped
{
    NSString *md = [NSString stringWithFormat:
        @"Intro.\n\n![img](data:image/png;base64,%@)\n\n<table><tr>"
        @"<td>Lea County</td><td>Lea County</td><td>Lea County</td>"
        @"</tr></table>", MPRepeat(@"A", 200000)];
    NSArray *texts = @[@"Intro.", @"Lea County", @"Lea County",
                       @"Lea County"];
    XCTAssertEqual(MPLocate(texts, nil, 3, 4, md),
                   MPNth(md, @"Lea County", 2) + 4,
                   @"Third cell should resolve to the third occurrence");
}

/**
 * Test that the clicked word is found when the search position lags more
 * than the search window behind it. Fails without step 2.
 */
- (void)testClickedUnitBeyondSearchWindow
{
    NSString *spans = MPRepeat(@"<span></span>", 60000);
    NSString *md = [NSString stringWithFormat:
        @"start here\n\n%@\n\nuniqueword target", spans];
    NSArray *texts = @[@"start here", @"Generated junk one",
                       @"Generated junk two", @"uniqueword target"];
    XCTAssertEqual(MPLocate(texts, nil, 3, 11, md),
                   [md rangeOfString:@"target"].location,
                   @"Click should resolve to the clicked word");
}

/**
 * Test that a click on text found nowhere in the source falls back to the
 * nearest preceding matched position, or 0 if nothing matched.
 */
- (void)testNothingMatchesReturnsPointer
{
    NSString *md = @"Hello world.\n\nOther.\n\nFinal.";
    NSArray *texts = @[@"Hello world.", @"Other.", @"Nothing here",
                       @"Final."];
    XCTAssertEqual(MPLocate(texts, nil, 2, 3, md),
                   NSMaxRange([md rangeOfString:@"Other."]),
                   @"Unmatched text should resolve to the last match's end");
    XCTAssertEqual(MPLocate(@[@"zzzz yyyy"], nil, 0, 2, md), 0u,
                   @"With no match at all the result should be 0");
}

/**
 * Test out-of-range indexes and offsets, empty inputs, and offsets on a
 * separator.
 */
- (void)testEdgeCases
{
    NSString *md = @"Hello world.";
    XCTAssertEqual(MPLocate(@[@"Hello world."], nil, 0, 6, md), 6u,
                   @"An exact match should map offset for offset");
    XCTAssertEqual(MPLocate(@[], nil, 0, 0, md), 0u,
                   @"No texts should resolve to 0");
    XCTAssertEqual(MPLocate(@[@"Hello world."], nil, 3, 0, md), 0u,
                   @"An index past the texts should resolve to 0");
    XCTAssertEqual(MPLocate(@[@"Hello world."], nil, 0, 100, md), 12u,
                   @"An offset past the node end is clamped");
    XCTAssertEqual(MPLocate(@[@"It’s here"], nil, 0, 2, @"It's here"),
                   2u, @"An offset on a separator uses the unit before it");
    XCTAssertEqual(MPLocate(@[@"x"], nil, 0, 0, @""), 0u,
                   @"An empty source should resolve to 0");
}

/**
 * Test that locating a click at the end of a document of over 500,000
 * characters, copied from an NSTextStorage as the app does, takes under
 * 100 ms.
 */
- (void)testPerformance
{
    NSMutableString *md = [NSMutableString string];
    NSMutableArray *texts = [NSMutableArray array];
    for (NSUInteger i = 0; i < 20000; i++)
    {
        NSString *line = [NSString stringWithFormat:
            @"Item %lu of Lea County.", (unsigned long)i];
        [md appendFormat:@"%@\n\n", line];
        [texts addObject:line];
        if (i % 50 == 25)
        {
            [texts addObject:[NSString stringWithFormat:
                @"Generated note %lu", (unsigned long)i]];
        }
    }
    XCTAssertGreaterThan(md.length, 500000u,
                         @"Precondition: the document is large");

    // Copy the string the way the app does, from an NSTextStorage.
    NSTextStorage *storage = [[NSTextStorage alloc] initWithString:md];
    NSUInteger index = texts.count - 1;
    NSUInteger expected = [md rangeOfString:texts[index]
                                    options:NSBackwardsSearch].location + 5;

    NSDate *start = [NSDate date];
    NSString *copy = [storage.string copy];
    NSUInteger location = MPLocate(texts, nil, index, 5, copy);
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;
    XCTAssertEqual(location, expected,
                   @"Click should resolve to the last line");
    XCTAssertLessThan(elapsed, 0.1, @"Took %.1f ms", elapsed * 1000);

    [self measureBlock:^{
        NSString *copy = [storage.string copy];
        MPLocate(texts, nil, index, 5, copy);
    }];
}


#pragma mark - Through the real renderer

- (MPRevealPreview *)previewForMarkdown:(NSString *)markdown
                              configure:(void (^)(MPRevealPreview *))configure
{
    MPRevealPreview *preview =
        [[MPRevealPreview alloc] initWithMarkdown:markdown
                                        configure:configure];
    XCTAssertTrue([preview waitUntilReady], @"The preview must load");
    return preview;
}

- (void)assertRevealOf:(NSString *)marker nth:(NSUInteger)nth
            inMarkdown:(NSString *)md sourceNth:(NSUInteger)sourceNth
             configure:(void (^)(MPRevealPreview *))configure
{
    MPRevealPreview *preview = [self previewForMarkdown:md
                                              configure:configure];
    XCTAssertTrue([preview setPointAtMarker:marker nth:nth],
                  @"Marker %@ must be in the preview", marker);
    XCTAssertEqual([preview locateCollected], MPNth(md, marker, sourceNth),
                   @"Reveal of %@ in: %@", marker, md);
}

/**
 * Test that a click in a rendered heading resolves to the heading text.
 */
- (void)testRendererHeading
{
    [self assertRevealOf:@"Heading" nth:0
              inMarkdown:@"# Title One\n\nBody.\n\n## Second Heading\n\nMore."
               sourceNth:0 configure:nil];
}

/**
 * Test that a click in rendered emphasis resolves to the emphasised text.
 */
- (void)testRendererEmphasis
{
    [self assertRevealOf:@"words" nth:0
              inMarkdown:@"Some *emphasised words* here and there."
               sourceNth:0 configure:nil];
}

/**
 * Test that a click in a rendered nested list item resolves to its text.
 */
- (void)testRendererNestedListItem
{
    [self assertRevealOf:@"item" nth:0
              inMarkdown:@"- outer\n    - inner item text\n- other"
               sourceNth:0 configure:nil];
}

/**
 * Test that a click in a rendered fenced code block resolves to the
 * clicked line.
 */
- (void)testRendererFencedCode
{
    [self assertRevealOf:@"other" nth:0
              inMarkdown:@"Intro.\n\n```\nlet value = 42;\nlet other = 7;\n```"
               sourceNth:0 configure:nil];
}

/**
 * Test that a click in the third of three identical rendered table cells
 * resolves to the third cell.
 */
- (void)testRendererRepeatedTableCells
{
    NSString *md = @"Intro.\n\n<table><tr><td>Lea County</td><td>Oil</td>"
        @"<td>Lea County</td><td>Gas</td><td>Lea County</td></tr></table>";
    [self assertRevealOf:@"Lea County" nth:2 inMarkdown:md sourceNth:2
               configure:nil];
}

/**
 * Test that a point recorded on a table cell element rather than a text
 * node resolves to the start of that cell's text.
 */
- (void)testRendererTableCellElementPoint
{
    NSString *md = @"Intro.\n\n<table><tr><td>Lea County</td><td>Oil</td>"
        @"<td>Lea County</td><td>Gas</td><td>Lea County</td></tr></table>";
    MPRevealPreview *preview = [self previewForMarkdown:md configure:nil];
    [preview evaluate:@"window.macdownRevealPoint = {"
        @"node: document.querySelectorAll('td')[2], offset: 0}"];
    XCTAssertEqual([preview locateCollected], MPNth(md, @"Lea County", 1),
                   @"Element point should resolve to the second cell");
}

/**
 * Test that a click in the paragraph after a rendered TOC resolves to that
 * paragraph. Fails without the TOC exclusion: each TOC entry is confirmed
 * by the next one, carrying the search position past section A.
 */
- (void)testRendererParagraphAfterTOC
{
    NSString *md = @"[TOC]\n\n# Section A\n\nText of section A.\n\n"
        @"# Section B\n\nText of section B.\n\n"
        @"# Section C\n\nText of section C.";
    [self assertRevealOf:@"Text of section A" nth:0 inMarkdown:md
               sourceNth:0 configure:^(MPRevealPreview *preview) {
        preview.delegate.renderTOC = YES;
    }];
}

/**
 * Test that the orphan TOC entries Hoedown emits outside ul.toc are inside
 * the .macdown-toc wrapper and so are excluded. Fails without the wrapper.
 */
- (void)testRendererOrphanTOCEntries
{
    NSString *md = @"[TOC]\n\n## Abstract\n\nAbstract body text.\n\n"
        @"# Introduction\n\nIntro body text.\n\n# Methods\n\n"
        @"Methods body text.";
    MPRevealPreview *preview = [self previewForMarkdown:md
                                              configure:^(MPRevealPreview *p) {
        p.delegate.renderTOC = YES;
    }];
    XCTAssertTrue([[preview evaluate:
        @"(function () {"
        @"  var lis = document.querySelectorAll('.macdown-toc li');"
        @"  for (var i = 0; i < lis.length; i++) {"
        @"    if (!lis[i].closest('ul.toc')) return true;"
        @"  }"
        @"  return false;"
        @"})()"] toBool], @"Precondition: an orphan TOC entry exists");
    XCTAssertTrue([preview setPointAtMarker:@"Abstract body" nth:0],
                  @"Marker should be in the preview");
    XCTAssertEqual([preview locateCollected],
                   [md rangeOfString:@"Abstract body"].location,
                   @"Click should resolve to the abstract body");
}

/**
 * Test that a rendered footnote reference number is excluded. Fails without
 * the footnote-reference exclusion: the "1" is matched in "2019", where the
 * emphasised text after it confirms it.
 */
- (void)testRendererFootnoteReferenceNumber
{
    NSString *md = @"Body with a note[^a] *and more words* here. "
        @"Reported in 2019 *and more words* here.\n\n"
        @"[^a]: Note text.";
    [self assertRevealOf:@"more words" nth:0 inMarkdown:md sourceNth:0
               configure:nil];
}

/**
 * Test that the code-block language label is excluded as generated text
 * (MacDown highlights json as JavaScript); the same code and paragraph
 * later in the document would otherwise confirm it there.
 */
- (void)testRendererCodeBlockLanguageLabel
{
    NSString *md = @"```json\n{\"key\": 1}\n```\n\n"
        @"Middle paragraph to click.\n\nLater: JavaScript\n\n"
        @"```\n{\"key\": 1}\n```\n\nMiddle paragraph to click.";
    MPRevealPreview *preview = [self previewForMarkdown:md
                                              configure:^(MPRevealPreview *p) {
        p.delegate.syntaxHighlighting = YES;
        p.delegate.codeBlockAccessory = MPCodeBlockAccessoryLanguageName;
    }];
    XCTAssertTrue([preview waitFor:
        @"!!document.querySelector('.prism-show-language')"],
        @"Precondition: the language label is shown");
    XCTAssertEqualObjects([[preview evaluate:
        @"document.querySelector('.prism-show-language').textContent"]
        toString], @"JavaScript",
        @"Precondition: the label reads JavaScript");
    XCTAssertTrue([preview setPointAtMarker:@"Middle" nth:0],
                  @"Marker should be in the preview");
    XCTAssertEqual([preview locateCollected], MPNth(md, @"Middle", 0),
                   @"Click should resolve to the first paragraph");
}

/**
 * Test that a point in a node no longer in the document, or no point at
 * all, is reported as index -1.
 */
- (void)testRendererDetachedPoint
{
    MPRevealPreview *preview = [self previewForMarkdown:@"Some text."
                                              configure:nil];
    [preview evaluate:
        @"var p = document.createElement('p');"
        @"p.textContent = 'gone';"
        @"document.body.appendChild(p);"
        @"window.macdownRevealPoint = {node: p.firstChild, offset: 1};"
        @"document.body.removeChild(p);"];
    XCTAssertEqual([[preview collect][@"index"] integerValue], -1,
                   @"A detached point should have index -1");
    [preview evaluate:@"window.macdownRevealPoint = null"];
    XCTAssertEqual([[preview collect][@"index"] integerValue], -1,
                   @"No point should have index -1");
}

/**
 * Test that a point inside the TOC resolves to the start of the next
 * collected node.
 */
- (void)testRendererPointInsideTOCResolvesToNextNode
{
    NSString *md = @"[TOC]\n\n# Section A\n\nText of section A.";
    MPRevealPreview *preview = [self previewForMarkdown:md
                                              configure:^(MPRevealPreview *p) {
        p.delegate.renderTOC = YES;
    }];
    [preview evaluate:
        @"var a = document.querySelector('.macdown-toc a');"
        @"window.macdownRevealPoint = {node: a.firstChild, offset: 3};"];
    NSDictionary *info = [preview collect];
    NSUInteger index = [info[@"index"] unsignedIntegerValue];
    XCTAssertEqualObjects(info[@"texts"][index], @"Section A",
                          @"The point should move to the next heading");
    XCTAssertEqual([info[@"offset"] integerValue], 0,
                   @"The point should move to the start of the heading");
    XCTAssertEqual([preview locateCollected],
                   [md rangeOfString:@"Section A"].location,
                   @"Click should resolve to the heading");
}

/**
 * Test that the collected footnote indexes follow the rendered footnote
 * order.
 */
- (void)testRendererFootnoteIndexes
{
    NSString *md = @"First[^b] then[^a].\n\n[^a]: Alpha text.\n\n"
        @"[^b]: Bravo text.";
    MPRevealPreview *preview = [self previewForMarkdown:md configure:nil];
    XCTAssertTrue([preview setPointAtMarker:@"Alpha" nth:0],
                  @"Marker should be in the preview");
    NSDictionary *info = [preview collect];
    NSUInteger index = [info[@"index"] unsignedIntegerValue];
    XCTAssertEqual([info[@"footnotes"][index] integerValue], 1,
                   @"The [^a] footnote should be the second rendered");
    XCTAssertEqual([preview locateCollected],
                   [md rangeOfString:@"Alpha"].location,
                   @"Click should resolve to the [^a] definition");
}


#pragma mark - Preview events

- (MPRevealPreview *)eventPreview
{
    NSString *md = @"- [ ] Task item\n\n[A link](http://example.com/target)"
        @"\n\nPlain paragraph here.";
    return [self previewForMarkdown:md configure:^(MPRevealPreview *p) {
        p.renderer.rendererFlags = HOEDOWN_HTML_USE_TASK_LIST;
    }];
}

/**
 * Test that option-clicking a checkbox requests a reveal, with the bridge
 * token, instead of toggling the checkbox.
 */
- (void)testOptionClickOnCheckboxRevealsInsteadOfToggling
{
    MPRevealPreview *preview = [self eventPreview];
    XCTAssertTrue([preview waitFor:
        @"!!document.querySelector('.task-list-item input')"],
        @"Precondition: the checkbox is rendered");
    [preview dispatch:@"click" at:@".task-list-item input" alt:YES];
    [preview spinFor:0.3];

    XCTAssertEqual([preview.recorder requestsWithScheme:
                    @"x-macdown-checkbox"].count, 0u,
                   @"No checkbox toggle should be requested");
    XCTAssertFalse([[preview evaluate:
        @"document.querySelector('.task-list-item input').checked"] toBool],
        @"The checkbox must not change");
    NSArray *reveals = [preview.recorder requestsWithScheme:
                        @"x-macdown-reveal"];
    XCTAssertEqual(reveals.count, 1u, @"One reveal should be requested");
    NSString *expected = [@"token=" stringByAppendingString:
                          preview.renderer.checkboxBridgeToken];
    XCTAssertEqualObjects([reveals.firstObject query], expected,
                          @"The reveal should carry the bridge token");
    XCTAssertTrue([[preview evaluate:
        @"!!(window.macdownRevealPoint && window.macdownRevealPoint.node)"]
        toBool], @"The clicked point should be recorded");
}

/**
 * Test that option-clicking a link requests a reveal instead of following
 * the link.
 */
- (void)testOptionClickOnLinkDoesNotFollowIt
{
    MPRevealPreview *preview = [self eventPreview];
    [preview dispatch:@"click" at:@"a" alt:YES];
    [preview spinFor:0.3];
    XCTAssertEqual([preview.recorder requestsWithScheme:@"http"].count, 0u,
                   @"The link should not be followed");
    XCTAssertEqual([preview.recorder requestsWithScheme:
                    @"x-macdown-reveal"].count, 1u,
                   @"One reveal should be requested");
}

/**
 * Test that a plain click on a checkbox still toggles it and does not
 * request a reveal.
 */
- (void)testPlainClickOnCheckboxStillToggles
{
    MPRevealPreview *preview = [self eventPreview];
    XCTAssertTrue([preview waitFor:
        @"!!document.querySelector('.task-list-item input')"],
        @"Precondition: the checkbox is rendered");
    [preview dispatch:@"click" at:@".task-list-item input" alt:NO];
    [preview spinFor:0.3];
    XCTAssertEqual([preview.recorder requestsWithScheme:
                    @"x-macdown-checkbox"].count, 1u,
                   @"One checkbox toggle should be requested");
    XCTAssertEqual([preview.recorder requestsWithScheme:
                    @"x-macdown-reveal"].count, 0u,
                   @"No reveal should be requested");
}

/**
 * Test that a right-click (contextmenu event) records the clicked point.
 */
- (void)testContextMenuRecordsPoint
{
    MPRevealPreview *preview = [self eventPreview];
    [preview evaluate:@"window.macdownRevealPoint = null"];
    NSString *selector = @"p:last-of-type";
    [preview dispatch:@"contextmenu" at:selector alt:NO];
    XCTAssertTrue([[preview evaluate:
        @"(function () {"
        @"  var point = window.macdownRevealPoint;"
        @"  var p = document.querySelector('p:last-of-type');"
        @"  return !!(point && point.node && p.contains(point.node)"
        @"      && p.textContent.indexOf('Plain paragraph') >= 0);"
        @"})()"] toBool],
        @"The point should be recorded in the right-clicked paragraph");
}


#pragma mark - Document

/**
 * Test that the preview context menu starts with "Reveal in Editor" when
 * the editor is visible, and omits it when the editor is collapsed.
 */
- (void)testContextMenuItemOnlyWhenEditorVisible
{
    MPDocument *document = [[MPDocument alloc] init];
    NSView *container =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
    document.editorContainer = container;
    NSDictionary *element = @{};

    NSArray *items = [document webView:nil contextMenuItemsForElement:element
                      defaultMenuItems:@[]];
    NSArray *titles = [items valueForKey:@"title"];
    XCTAssertTrue([titles containsObject:@"Reveal in Editor"],
                  @"The menu should offer Reveal in Editor");
    XCTAssertEqualObjects([items.firstObject title], @"Reveal in Editor",
                          @"Reveal in Editor should be the first item");

    container.frame = NSMakeRect(0, 0, 0, 300);
    items = [document webView:nil contextMenuItemsForElement:element
             defaultMenuItems:@[]];
    titles = [items valueForKey:@"title"];
    XCTAssertFalse([titles containsObject:@"Reveal in Editor"],
                   @"The menu should not offer it with the editor hidden");
}

/**
 * Test that the reveal bridge ignores every x-macdown-reveal navigation,
 * and moves the editor's insertion point only for a reveal URL carrying the
 * renderer's token.
 */
- (void)testRevealBridgeRequiresToken
{
    NSString *md = @"First paragraph.\n\nSecond paragraph with target.";
    MPRevealPreview *preview = [self previewForMarkdown:md configure:nil];
    XCTAssertTrue([preview setPointAtMarker:@"target" nth:0],
                  @"Marker should be in the preview");

    MPDocument *document = [[MPDocument alloc] init];
    NSView *container =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
    MPEditorView *editor =
        [[MPEditorView alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
    editor.string = md;
    editor.selectedRange = NSMakeRange(0, 0);
    document.editorContainer = container;
    document.editor = editor;
    document.preview = preview.webView;
    document.renderer = preview.renderer;

    NSString *token = preview.renderer.checkboxBridgeToken;
    XCTAssertTrue(token.length, @"Precondition: the renderer has a token");
    NSArray *rejected = @[
        @"x-macdown-reveal://reveal",
        @"x-macdown-reveal://reveal?token=wrong",
        [@"x-macdown-reveal://other?token=" stringByAppendingString:token],
    ];
    for (NSString *string in rejected)
    {
        MPRevealDecisionListener *listener =
            [[MPRevealDecisionListener alloc] init];
        NSURLRequest *request =
            [NSURLRequest requestWithURL:[NSURL URLWithString:string]];
        [document webView:preview.webView
            decidePolicyForNavigationAction:@{} request:request
            frame:preview.webView.mainFrame decisionListener:listener];
        XCTAssertTrue(listener.ignored,
                      @"Navigation to %@ should be ignored", string);
        XCTAssertEqual(editor.selectedRange.location, 0u, @"%@", string);
    }

    MPRevealDecisionListener *listener =
        [[MPRevealDecisionListener alloc] init];
    NSURL *url = [NSURL URLWithString:
        [@"x-macdown-reveal://reveal?token=" stringByAppendingString:token]];
    [document webView:preview.webView
        decidePolicyForNavigationAction:@{}
        request:[NSURLRequest requestWithURL:url]
        frame:preview.webView.mainFrame decisionListener:listener];
    XCTAssertTrue(listener.ignored, @"The reveal navigation should be ignored");
    XCTAssertEqual(editor.selectedRange.location,
                   [md rangeOfString:@"target"].location,
                   @"The insertion point should move to the clicked text");
    XCTAssertEqual(editor.selectedRange.length, 0u,
                   @"The selection should be empty");
}

@end
