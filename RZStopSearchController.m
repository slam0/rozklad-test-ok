#import "RZStopSearchController.h"
#import "RZCitiesController.h"
#import "RZImportController.h"
#import "RZLang.h"
#import "RZViews.h"

#define kMaxStops 20            /* tyle samo przystanków naraz, żeby pobieranie było krótkie */
#define kMaxResults 120

static NSString *Fold(NSString *s)
{
    return [s stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch | NSWidthInsensitiveSearch
                                  locale:nil];
}

static NSString *KindsText(NSUInteger mask)
{
    NSMutableArray *a = [NSMutableArray array];
    if (mask & 1) [a addObject:RZL(@"Autobus")];
    if (mask & 2) [a addObject:RZL(@"Tramwaj")];
    if (mask & 4) [a addObject:RZL(@"Pociąg")];
    if (mask & 8) [a addObject:RZL(@"Metro")];
    return [a componentsJoinedByString:@", "];
}

@implementation RZStopSearchController {
    NSDictionary *_city;
    NSString *_base;
    NSDictionary *_index;           /* cały index.json */
    NSArray *_groups;               /* index[@"g"] */
    NSMutableArray *_folded;        /* nazwy bez ogonków, małymi literami (NSString) */
    NSMutableArray *_selected;      /* numery grup w kolejności wyboru (NSNumber) */
    NSArray *_shown;                /* numery grup widoczne na liście */
    UISearchBar *_search;
    UITableView *_table;
    UILabel *_msg;
    UIActivityIndicatorView *_spin;
    BOOL _ready;
}

- (id)initWithCity:(NSDictionary *)city baseURL:(NSString *)base
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _city = city;
        _base = [base copy];
        _selected = [NSMutableArray array];
        _shown = [NSArray array];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = [_city objectForKey:@"n"];
    self.view.backgroundColor = RZPaperColor();

    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    _search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _search.placeholder = RZL(@"Szukaj przystanku");
    _search.delegate = self;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _search.userInteractionEnabled = NO;
    [self.view addSubview:_search];

    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 44, self.view.bounds.size.width, self.view.bounds.size.height - 44)
                                          style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    RZStyleTable(_table);
    [self.view addSubview:_table];

    _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spin.center = CGPointMake(self.view.bounds.size.width / 2, 100);
    _spin.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_spin];

    _msg = [[UILabel alloc] initWithFrame:CGRectMake(20, 130, self.view.bounds.size.width - 40, 160)];
    _msg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _msg.backgroundColor = [UIColor clearColor];
    _msg.textColor = RZSubtleColor();
    _msg.textAlignment = NSTextAlignmentCenter;
    _msg.numberOfLines = 0;
    _msg.font = [UIFont systemFontOfSize:15];
    [self.view addSubview:_msg];

    [self updateButton];
    [self load];
}

- (void)load
{
    _msg.text = RZL(@"Pobieram listę przystanków…");
    [_spin startAnimating];
    NSString *url = [_base stringByAppendingString:@"index.json"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *why = nil;
        NSDictionary *idx = nil;
        NSMutableArray *folded = nil;
        NSData *d = RZFetch(url, 24u * 1024u * 1024u, &why);
        if (d) {
            id root = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
            if ([root isKindOfClass:[NSDictionary class]] && [[root objectForKey:@"g"] isKindOfClass:[NSArray class]] &&
                [root objectForKey:@"v"]) {
                idx = root;
                NSArray *g = [root objectForKey:@"g"];
                folded = [NSMutableArray arrayWithCapacity:[g count]];
                for (NSArray *row in g) {
                    NSString *n = ([row count] > 1 && [[row objectAtIndex:1] isKindOfClass:[NSString class]] &&
                                   [[row objectAtIndex:1] length]) ? [row objectAtIndex:1] : [row objectAtIndex:0];
                    [folded addObject:Fold(n)];
                }
            } else {
                why = RZL(@"Lista przystanków ma zły format.");
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [_spin stopAnimating];
            if (!idx) {
                _msg.text = [NSString stringWithFormat:@"%@\n\n%@", RZL(@"Nie udało się pobrać listy przystanków."), why ? why : @""];
                return;
            }
            _index = idx;
            _groups = [idx objectForKey:@"g"];
            _folded = folded;
            _ready = YES;
            _search.userInteractionEnabled = YES;
            [self refilter];
            [_search becomeFirstResponder];
        });
    });
}

#pragma mark - Filtr

- (void)refilter
{
    NSString *q = [Fold([_search.text length] ? _search.text : @"")
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *out = [NSMutableArray array];
    NSString *note = @"";
    if ([q length] < 2) {
        [out addObjectsFromArray:_selected];
        note = [_selected count] ? @"" : RZL(@"Wpisz co najmniej 2 litery nazwy przystanku.");
    } else {
        for (int pass = 0; pass < 2 && [out count] < kMaxResults; pass++) {
            for (NSUInteger i = 0; i < [_groups count] && [out count] < kMaxResults; i++) {
                NSString *k = [_folded objectAtIndex:i];
                NSRange r = [k rangeOfString:q];
                if (r.location == NSNotFound) continue;
                BOOL start = (r.location == 0) || [k rangeOfString:[@" " stringByAppendingString:q]].location != NSNotFound;
                if ((pass == 0) != start) continue;     /* najpierw początek słowa, potem reszta */
                [out addObject:[NSNumber numberWithUnsignedInteger:i]];
            }
        }
        if (![out count]) note = RZL(@"Nic nie znaleziono.");
    }
    _shown = out;
    _msg.text = note;
    _msg.frame = CGRectMake(20, 60, self.view.bounds.size.width - 40, 100);
    _msg.hidden = ([note length] == 0);
    [_table reloadData];
}

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text
{
    if (_ready) [self refilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb
{
    [sb resignFirstResponder];
}

#pragma mark - Wybór

- (NSUInteger)selectedPoleCount
{
    NSUInteger n = 0;
    for (NSNumber *gi in _selected) n += [[[_groups objectAtIndex:[gi unsignedIntegerValue]] objectAtIndex:5] count];
    return n;
}

- (void)updateButton
{
    if ([_selected count] == 0) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    NSString *t = [NSString stringWithFormat:@"%@ (%lu)", RZL(@"Pobierz"), (unsigned long)[_selected count]];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:t style:UIBarButtonItemStyleDone target:self action:@selector(downloadTapped)];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)[_shown count]; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"stop"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"stop"];
    NSNumber *gi = [_shown objectAtIndex:ip.row];
    NSArray *g = [_groups objectAtIndex:[gi unsignedIntegerValue]];
    cell.textLabel.text = [g objectAtIndex:0];
    NSMutableArray *codes = [NSMutableArray array];
    for (NSArray *p in [g objectAtIndex:5]) {
        NSString *c = [p count] > 1 ? [NSString stringWithFormat:@"%@", [p objectAtIndex:1]] : @"";
        if ([c length]) [codes addObject:c];
        if ([codes count] >= 6) break;
    }
    NSString *kinds = KindsText([[g objectAtIndex:2] unsignedIntegerValue]);
    cell.detailTextLabel.text = [codes count] ? [NSString stringWithFormat:@"%@ · %@", kinds, [codes componentsJoinedByString:@", "]] : kinds;
    cell.accessoryType = [_selected containsObject:gi] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip
{
    RZStyleCell(cell);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSNumber *gi = [_shown objectAtIndex:ip.row];
    if ([_selected containsObject:gi]) {
        [_selected removeObject:gi];
    } else {
        NSUInteger poles = [[[_groups objectAtIndex:[gi unsignedIntegerValue]] objectAtIndex:5] count];
        if ([_selected count] >= kMaxStops || [self selectedPoleCount] + poles > 380) {
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:RZL(@"Za dużo przystanków")
                                                        message:[NSString stringWithFormat:RZL(@"Naraz można wybrać do %d przystanków. Odznacz któryś, żeby dodać nowy."), kMaxStops]
                                                       delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [a show];
            return;
        }
        [_selected addObject:gi];
    }
    [self updateButton];
    [tv reloadRowsAtIndexPaths:[NSArray arrayWithObject:ip] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s
{
    NSString *a = [_city objectForKey:@"a"];
    return [a length] ? [NSString stringWithFormat:RZL(@"Dane: %@"), a] : nil;
}

#pragma mark - Pobieranie

static NSString *Escape(NSString *s)
{
    return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault, (__bridge CFStringRef)s, NULL, CFSTR("!*'();:@&=+$,/?#[]%"), kCFStringEncodingUTF8);
}

- (void)downloadTapped
{
    if (![_selected count]) return;
    [_search resignFirstResponder];

    /* ten sam słupek może należeć do kilku przystanków: łączymy rodzaje (jak robił to kreator na stronie) */
    NSMutableDictionary *mask = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    for (NSNumber *gi in _selected) {
        NSArray *g = [_groups objectAtIndex:[gi unsignedIntegerValue]];
        for (NSArray *p in [g objectAtIndex:5]) {
            NSNumber *num = [p objectAtIndex:0];
            NSUInteger m = [[p objectAtIndex:2] unsignedIntegerValue];
            NSNumber *old = [mask objectForKey:num];
            if (!old) [order addObject:num];
            [mask setObject:[NSNumber numberWithUnsignedInteger:m | [old unsignedIntegerValue]] forKey:num];
        }
    }
    NSMutableArray *parts = [NSMutableArray array];
    for (NSNumber *n in order) [parts addObject:[NSString stringWithFormat:@"%@.%@", n, [mask objectForKey:n]]];
    NSString *url = [NSString stringWithFormat:@"rozklad://import?u=%@&v=%@&p=%@",
                     Escape(_base), [_index objectForKey:@"v"], [parts componentsJoinedByString:@","]];

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:[_city objectForKey:@"n"] forKey:@"pending_city_name"];
    [d setObject:([[_city objectForKey:@"a"] length] ? [_city objectForKey:@"a"] : @"") forKey:@"pending_city_attr"];
    [d synchronize];

    /* zamykamy okno wyboru i na jego miejscu pokazujemy okno pobierania */
    UIViewController *host = self.navigationController.presentingViewController;
    RZImportController *ic = [[RZImportController alloc] initWithURLString:url];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:ic];
    RZStyleNavigationBar(nav.navigationBar);
    [host dismissViewControllerAnimated:NO completion:^{
        [host presentViewController:nav animated:YES completion:nil];
    }];
}

@end
