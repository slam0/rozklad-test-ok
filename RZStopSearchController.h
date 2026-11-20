#import <UIKit/UIKit.h>

/* Wybór przystanków w jednym mieście: pobiera index.json miasta, szuka po nazwie,
   a po dotknięciu "Pobierz" otwiera okno pobierania (RZImportController). */
@interface RZStopSearchController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
- (id)initWithCity:(NSDictionary *)city baseURL:(NSString *)base;
@end
