#import "RZStopSearchController.h"
#import <QuartzCore/QuartzCore.h>
#import "RZCitiesController.h"
#import "RZImportController.h"
#import "RZLang.h"
#import "RZViews.h"

#define kMaxPerKind 10          /* tyle samo co w kreatorze na stronie */
#define kMaxPoles 380           /* aplikacja przyjmuje do 400 słupków naraz */
#define kMaxResults 120

static NSString *Fold(NSString *s)
{
    return [s stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch | NSWidthInsensitiveSearch
                                  locale:nil];
}

static NSString *KindTitle(NSUInteger bit)
{
    switch (bit) {
        case 1:  return RZL(@"Autobusy");
        case 2:  return RZL(@"Tramwaje");
        case 4:  return RZL(@"Pociągi");
        default: return RZL(@"Metro");
    }
}

@implementation RZStopSearchController {
    NSDictionary *_city;
    NSString *_base;
    NSDictionary *_index;           /* cały index.json */
    NSArray *_groups;               /* index[@"g"] */
    NSMutableArray *_folded;        /* nazwy bez ogonków, małymi literami */
    NSMutableArray *_steps;         /* rodzaje dostępne w mieście: NSNumber 1,2,4,8 */
    NSMutableDictionary *_chosen;   /* rodzaj -> NSMutableArray numerów grup (NSNumber) */
    NSInteger _step;
    NSArray *_shown;                /* numery grup widoczne na liście */
    UIView *_bar;                   /* pasek kroków: kółko z numerem, nazwa rodzaju i liczba wybranych */
    NSMutableArray *_btns;
    NSMutableArray *_nameLabels;
    NSMutableArray *_countLabels;
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
        _shown = [NSArray array];
        _chosen = [NSMutableDictionary dictionary];
        _steps = [NSMutableArray array];
        NSUInteger mask = [[city objectForKey:@"m"] unsignedIntegerValue];
        if (!mask) mask = 15;
        for (NSUInteger bit = 1; bit <= 8; bit <<= 1) {
            if (mask & bit) {
                [_steps addObject:[NSNumber numberWithUnsignedInteger:bit]];
                [_chosen setObject:[NSMutableArray array] forKey:[NSNumber numberWithUnsignedInteger:bit]];
            }
        }
        if (![_steps count]) { [_steps addObject:[NSNumber numberWithInt:1]]; [_chosen setObject:[NSMutableArray array] forKey:[NSNumber numberWithInt:1]]; }
    }
    return self;
}

- (NSUInteger)bit { return [[_steps objectAtIndex:(NSUInteger)_step] unsignedIntegerValue]; }

- (NSMutableArray *)list { return [_chosen objectForKey:[_steps objectAtIndex:(NSUInteger)_step]]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = [_city objectForKey:@"n"];
    self.view.backgroundColor = RZPaperColor();
    CGFloat w = self.view.bounds.size.width;

    [self buildBar:w];

    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 58, w, 44)];
    _search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _search.placeholder = RZL(@"Szukaj przystanku");
    _search.delegate = self;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _search.userInteractionEnabled = NO;
    [self.view addSubview:_search];

    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 102, w, self.view.bounds.size.height - 102)
                                          style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    RZStyleTable(_table);
    [self.view addSubview:_table];

    _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spin.center = CGPointMake(w / 2, 140);
    _spin.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_spin];

    _msg = [[UILabel alloc] initWithFrame:CGRectMake(20, 170, w - 40, 160)];
    _msg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _msg.backgroundColor = [UIColor clearColor];
    _msg.textColor = RZSubtleColor();
    _msg.textAlignment = NSTextAlignmentCenter;
    _msg.numberOfLines = 0;
    _msg.font = [UIFont systemFontOfSize:15];
    [self.view addSubview:_msg];

    [self updateHeader];
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

#pragma mark - Kroki

- (NSUInteger)totalStops
{
    NSUInteger n = 0;
    for (NSNumber *b in _steps) n += [[_chosen objectForKey:b] count];
    return n;
}

- (void)updateHeader
{
    for (NSUInteger i = 0; i < [_steps count]; i++) {
        BOOL on = ((NSInteger)i == _step);
        UIButton *btn = [_btns objectAtIndex:i];
        btn.backgroundColor = on ? RZBrownColor() : [UIColor colorWithRed:0.98f green:0.96f blue:0.90f alpha:1.0f];
        UILabel *nl = [_nameLabels objectAtIndex:i];
        UILabel *cl = [_countLabels objectAtIndex:i];
        nl.textColor = on ? [UIColor whiteColor] : RZBrownColor();
        cl.textColor = on ? [UIColor colorWithWhite:1.0f alpha:0.8f] : [UIColor colorWithWhite:0.45f alpha:1.0f];
        NSUInteger n = [[_chosen objectForKey:[_steps objectAtIndex:i]] count];
        cl.text = [NSString stringWithFormat:RZL(@"%lu wybr."), (unsigned long)n];
    }
    BOOL last = (_step == (NSInteger)[_steps count] - 1);
    NSString *t = last ? [NSString stringWithFormat:@"%@ (%lu)", RZL(@"Pobierz"), (unsigned long)[self totalStops]] : RZL(@"Dalej");
    UIBarButtonItem *b = [[UIBarButtonItem alloc] initWithTitle:t
                                                          style:last ? UIBarButtonItemStyleDone : UIBarButtonItemStyleBordered
                                                         target:self action:@selector(nextTapped)];
    b.enabled = !last || [self totalStops] > 0;
    self.navigationItem.rightBarButtonItem = b;
}

static UIColor *KindColor(NSUInteger bit)
{
    switch (bit) {
        case 1:  return [UIColor colorWithRed:0.80f green:0.10f blue:0.18f alpha:1.0f];
        case 2:  return [UIColor colorWithRed:0.13f green:0.45f blue:0.82f alpha:1.0f];
        case 4:  return [UIColor colorWithRed:0.15f green:0.55f blue:0.25f alpha:1.0f];
        default: return [UIColor colorWithRed:0.10f green:0.20f blue:0.55f alpha:1.0f];
    }
}

/* Pasek kroków podobny do tego na stronie: kolorowe kółko z numerem, nazwa i liczba wybranych */
- (void)buildBar:(CGFloat)w
{
    _bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 58)];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _bar.backgroundColor = RZPaperColor();
    _btns = [NSMutableArray array];
    _nameLabels = [NSMutableArray array];
    _countLabels = [NSMutableArray array];
    for (NSUInteger i = 0; i < [_steps count]; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = (NSInteger)i;
        b.layer.cornerRadius = 7.0f;
        b.layer.borderWidth = 1.0f;
        b.layer.borderColor = [UIColor colorWithWhite:0.0f alpha:0.25f].CGColor;
        [b addTarget:self action:@selector(barTapped:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *num = [[UILabel alloc] init];
        num.tag = 101;
        num.backgroundColor = KindColor([[_steps objectAtIndex:i] unsignedIntegerValue]);
        num.textColor = [UIColor whiteColor];
        num.textAlignment = NSTextAlignmentCenter;
        num.font = [UIFont boldSystemFontOfSize:12];
        num.text = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
        num.layer.cornerRadius = 10.0f;
        num.userInteractionEnabled = NO;
        [b addSubview:num];

        UILabel *nl = [[UILabel alloc] init];
        nl.tag = 102;
        nl.backgroundColor = [UIColor clearColor];
        nl.textAlignment = NSTextAlignmentCenter;
        nl.font = [UIFont boldSystemFontOfSize:12];
        nl.adjustsFontSizeToFitWidth = YES;
        nl.minimumScaleFactor = 0.7f;
        nl.text = KindTitle([[_steps objectAtIndex:i] unsignedIntegerValue]);
        nl.userInteractionEnabled = NO;
        [b addSubview:nl];

        UILabel *cl = [[UILabel alloc] init];
        cl.tag = 103;
        cl.backgroundColor = [UIColor clearColor];
        cl.textAlignment = NSTextAlignmentCenter;
        cl.font = [UIFont systemFontOfSize:10];
        cl.userInteractionEnabled = NO;
        [b addSubview:cl];

        [_bar addSubview:b];
        [_btns addObject:b];
        [_nameLabels addObject:nl];
        [_countLabels addObject:cl];
    }
    [self.view addSubview:_bar];
    [self layoutBar];
}

- (void)layoutBar
{
    CGFloat w = self.view.bounds.size.width;
    NSUInteger n = [_btns count];
    if (!n) return;
    CGFloat gap = 4.0f, bw = (w - 16.0f - gap * (n - 1)) / n;
    for (NSUInteger i = 0; i < n; i++) {
        UIButton *b = [_btns objectAtIndex:i];
        b.frame = CGRectMake(8.0f + i * (bw + gap), 4.0f, bw, 50.0f);
        [b viewWithTag:101].frame = CGRectMake((bw - 20.0f) / 2.0f, 3.0f, 20.0f, 20.0f);
        [b viewWithTag:102].frame = CGRectMake(2.0f, 24.0f, bw - 4.0f, 14.0f);
        [b viewWithTag:103].frame = CGRectMake(2.0f, 37.0f, bw - 4.0f, 12.0f);
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self layoutBar];
}

- (void)barTapped:(UIButton *)b
{
    if (b.tag == _step) return;
    _step = b.tag;
    _search.text = @"";
    [self updateHeader];
    [self refilter];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv
{
    [_search resignFirstResponder];     /* klawiatura zasłania listę, więc chowa się przy przewijaniu */
}

- (void)nextTapped
{
    if (_step < (NSInteger)[_steps count] - 1) {
        _step++;
        _search.text = @"";
        [self updateHeader];
        [self refilter];
    } else {
        [self downloadTapped];
    }
}

#pragma mark - Filtr

- (void)refilter
{
    NSUInteger bit = [self bit];
    NSString *q = [Fold([_search.text length] ? _search.text : @"")
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *out = [NSMutableArray array];
    NSString *note = @"";
    if ([q length] < 2) {
        [out addObjectsFromArray:[self list]];
        if ([[self list] count]) {
            note = @"";
        } else {
            NSString *a = [_city objectForKey:@"a"];
            note = [a length] ? [NSString stringWithFormat:@"%@\n\n%@", RZL(@"Wpisz co najmniej 2 litery nazwy przystanku."),
                                 [NSString stringWithFormat:RZL(@"Dane: %@"), a]]
                              : RZL(@"Wpisz co najmniej 2 litery nazwy przystanku.");
        }
    } else {
        for (int pass = 0; pass < 2 && [out count] < kMaxResults; pass++) {
            for (NSUInteger i = 0; i < [_groups count] && [out count] < kMaxResults; i++) {
                if (!([[[_groups objectAtIndex:i] objectAtIndex:2] unsignedIntegerValue] & bit)) continue;
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
    _msg.frame = CGRectMake(20, 124, self.view.bounds.size.width - 40, 120);
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

#pragma mark - Tabela

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)[_shown count]; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"stop"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"stop"];
    NSUInteger bit = [self bit];
    NSNumber *gi = [_shown objectAtIndex:ip.row];
    NSArray *g = [_groups objectAtIndex:[gi unsignedIntegerValue]];
    cell.textLabel.text = [g objectAtIndex:0];
    NSMutableArray *codes = [NSMutableArray array];
    for (NSArray *p in [g objectAtIndex:5]) {
        if (!([[p objectAtIndex:2] unsignedIntegerValue] & bit)) continue;
        NSString *c = [p count] > 1 ? [NSString stringWithFormat:@"%@", [p objectAtIndex:1]] : @"";
        if ([c length]) [codes addObject:c];
        if ([codes count] >= 8) break;
    }
    cell.detailTextLabel.text = [codes count] ? [NSString stringWithFormat:@"%@ %@", RZL(@"słupki:"), [codes componentsJoinedByString:@", "]] : @"";
    cell.textLabel.textColor = RZCellTextColor();
    cell.detailTextLabel.textColor = RZSubtleColor();
    cell.accessoryType = [[self list] containsObject:gi] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip
{
    RZStyleCell(cell);
}

- (BOOL)showingSelected
{
    NSString *q = [_search.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return [q length] < 2 && [[self list] count] > 0;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s
{
    if (![self showingSelected]) return nil;
    NSString *t = [NSString stringWithFormat:RZL(@"%@: wybrano %lu z %d"), KindTitle([self bit]), (unsigned long)[[self list] count], kMaxPerKind];
    return RZSectionHeaderView(t);
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s
{
    return [self showingSelected] ? 34.0f : 0.0f;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s
{
    NSString *a = [_city objectForKey:@"a"];
    if (![_shown count] || ![a length]) return nil;
    return RZSectionFooterView([NSString stringWithFormat:RZL(@"Dane: %@"), a]);
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s
{
    return ([_shown count] && [[_city objectForKey:@"a"] length]) ? 44.0f : 0.0f;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSNumber *gi = [_shown objectAtIndex:ip.row];
    NSMutableArray *list = [self list];
    if ([list containsObject:gi]) {
        [list removeObject:gi];
    } else {
        if ([list count] >= kMaxPerKind || [[self planPoles] count] + [self polesOfGroup:gi forBit:[self bit]] > kMaxPoles) {
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:RZL(@"Za dużo przystanków")
                                                        message:[NSString stringWithFormat:RZL(@"W jednym kroku można wybrać do %d przystanków. Odznacz któryś, żeby dodać nowy."), kMaxPerKind]
                                                       delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [a show];
            return;
        }
        [list addObject:gi];
    }
    [self updateHeader];
    [tv reloadData];
}

#pragma mark - Pobieranie

- (NSUInteger)polesOfGroup:(NSNumber *)gi forBit:(NSUInteger)bit
{
    NSUInteger n = 0;
    for (NSArray *p in [[_groups objectAtIndex:[gi unsignedIntegerValue]] objectAtIndex:5])
        if ([[p objectAtIndex:2] unsignedIntegerValue] & bit) n++;
    return n;
}

/* Jak plan() w kreatorze: słupki z wybranych przystanków, tylko te obsługujące dany rodzaj,
   a ten sam słupek w kilku rodzajach dostaje sumę bitów. Zwraca słownik numer -> maska i kolejność w _planOrder. */
- (NSDictionary *)planPoles
{
    NSMutableDictionary *mask = [NSMutableDictionary dictionary];
    for (NSNumber *b in _steps) {
        NSUInteger bit = [b unsignedIntegerValue];
        for (NSNumber *gi in [_chosen objectForKey:b]) {
            for (NSArray *p in [[_groups objectAtIndex:[gi unsignedIntegerValue]] objectAtIndex:5]) {
                if (!([[p objectAtIndex:2] unsignedIntegerValue] & bit)) continue;
                NSNumber *num = [p objectAtIndex:0];
                NSUInteger old = [[mask objectForKey:num] unsignedIntegerValue];
                [mask setObject:[NSNumber numberWithUnsignedInteger:old | bit] forKey:num];
            }
        }
    }
    return mask;
}

static NSString *Escape(NSString *s)
{
    return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault, (__bridge CFStringRef)s, NULL, CFSTR("!*'();:@&=+$,/?#[]%"), kCFStringEncodingUTF8);
}

- (void)downloadTapped
{
    NSDictionary *mask = [self planPoles];
    if (![mask count]) return;
    [_search resignFirstResponder];

    NSArray *nums = [[mask allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSNumber *n in nums) [parts addObject:[NSString stringWithFormat:@"%@.%@", n, [mask objectForKey:n]]];
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
