// Office C′ 表格（Sheet）批 1 —— 只读渲染器（证据驱动）离线测试。
//
// 夹具来源（**都是真实数据**，逐字内联，来源与 sha256 见每段顶部注释）：
//   * `spikeSections`：真机 `dart_frames_sheet.json` 那次 `Sheet.Snapshot:init` 的
//     同一份快照 —— `/tmp/office-collab-spike/evid/snapshot_sheet_pre.json` 的
//     `content`（自建 `spike_min.osheet`，单元格 `C3SPIKE-SHEET-BASE`）。
//   * `todoSections`：SPK 3.8.0-22711 官方模板
//     `/tmp/spk/export_Office/template/sheet/to_do_list_simple/text.json`
//     （真实样式池 + 真实公式 + 真实数值 + 5 个 mergeCells）。
//
// 无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/osheet_model.dart';
import 'package:synhub/src/features/office/office_sheet_chart.dart';
import 'package:synhub/src/features/office/office_sheet_schema.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_sheet_view.dart';

/// 真机快照 `content` 原文（sha256 见 docs/office-sheet-ui-1.md §⑨）。
const String spikeSectionsJson = r'''
{
 "index": {
  "gcVer": 1,
  "maxIndex": 1,
  "order": [
   "sh_1"
  ],
  "schemaVersion": 5,
  "sheets": {
   "sh_1": {
    "title": "C3Spike"
   }
  },
  "ver": 1
 },
 "style": {
  "alignments": [],
  "borders": [],
  "fills": [],
  "fonts": [],
  "numberFormats": [],
  "styles": []
 },
 "comment": [],
 "define": {},
 "pivotCaches": [],
 "pivotTables": [],
 "sh_1": {
  "cells": {
   "0": {
    "0": {
     "v": "C3SPIKE-SHEET-BASE"
    }
   }
  },
  "cfs": [],
  "colCount": 30,
  "colSpans": [],
  "cols": {},
  "drawing": [],
  "filter": {},
  "fixedColumnLeft": 0,
  "fixedRowTop": 0,
  "global": {
   "h": 21,
   "w": 101
  },
  "hyperlinks": [],
  "mergeCells": [],
  "notes": [],
  "rowCount": 100,
  "rows": {},
  "validation": {}
 },
 "locale": "en_US",
 "locale_info": {
  "currency": "USD",
  "currency_format": "[$$]#,##0.00",
  "currency_name": "US Dollar",
  "currency_sym": "$",
  "date_patterns": [
   "M/D/Y",
   "M/D"
  ],
  "days": [
   [
    "Sun",
    "Sunday"
   ],
   [
    "Mon",
    "Monday"
   ],
   [
    "Tue",
    "Tuesday"
   ],
   [
    "Wed",
    "Wednesday"
   ],
   [
    "Thu",
    "Thursday"
   ],
   [
    "Fri",
    "Friday"
   ],
   [
    "Sat",
    "Saturday"
   ]
  ],
  "dec_sym": ".",
  "group_sym": ",",
  "lcid": 1033,
  "long_day_period": [
   "AM",
   "PM"
  ],
  "long_time": "hh:mm:ss AM/PM",
  "months": [
   [
    "J",
    "Jan",
    "January"
   ],
   [
    "F",
    "Feb",
    "February"
   ],
   [
    "M",
    "Mar",
    "March"
   ],
   [
    "A",
    "Apr",
    "April"
   ],
   [
    "M",
    "May",
    "May"
   ],
   [
    "J",
    "Jun",
    "June"
   ],
   [
    "J",
    "Jul",
    "July"
   ],
   [
    "A",
    "Aug",
    "August"
   ],
   [
    "S",
    "Sep",
    "September"
   ],
   [
    "O",
    "Oct",
    "October"
   ],
   [
    "N",
    "Nov",
    "November"
   ],
   [
    "D",
    "Dec",
    "December"
   ]
  ],
  "short_date": "M/d/YYYY",
  "short_day_period": [
   "a",
   "p"
  ],
  "short_time": "hh:mm AM/PM",
  "pivot_table": {
   "datetime_group_item_label_quarter": "Quarter {0}",
   "default_column_labels_caption": "Column Labels",
   "default_data_field_name_template": "{1} of {0}",
   "default_group_name": "Group",
   "default_missing_item_label": "(Blank)",
   "default_row_labels_caption": "Row Labels",
   "default_values_field_caption": "Values",
   "grand_total": "Grand Total",
   "grand_total_with_data": "Total {0}",
   "page_filter_all": "(No items selected)",
   "page_filter_multi_item": "(Selected {0} items)",
   "subtotal_template": "{0} Total",
   "unnamed_group_name": "Unnamed group",
   "avg": "Average",
   "count": "Count",
   "count_a": "CountA",
   "max": "Maximum",
   "min": "Minimum",
   "product": "Product",
   "std_dev": "StdDev",
   "std_dev_p": "StdDevP",
   "sum": "Sum",
   "var": "Var",
   "var_p": "VarP",
   "or": "or",
   "date_group_days": "Days",
   "date_group_hours": "Hours",
   "date_group_minutes": "Minutes",
   "date_group_months": "Months",
   "date_group_quarters": "Quarters",
   "date_group_seconds": "Seconds",
   "date_group_years": "Years"
  }
 }
}
''';

/// 官方模板样本 `to_do_list_simple/text.json` 原文。
const String todoSectionsJson = r'''
{
 "comment": [],
 "define": {},
 "index": {
  "gcVer": 1,
  "maxIndex": 1,
  "order": [
   "sh_1"
  ],
  "schemaVersion": 5,
  "sheets": {
   "sh_1": {
    "deleted": false,
    "title": "To-Do List"
   }
  },
  "ver": 1
 },
 "sh_1": {
  "cells": {
   "0": {
    "0": {
     "s": 3
    },
    "1": {
     "s": 12,
     "v": "TO-DO LIST"
    },
    "2": {
     "s": 12
    },
    "3": {
     "s": 14
    },
    "4": {
     "s": 13,
     "v": "=CONCATENATE(COUNTA(C4:C34), \"/\", COUNTA(E4:E34), \" Completed  \")"
    },
    "5": {
     "s": 4
    }
   },
   "1": {
    "0": {
     "s": 3
    },
    "1": {
     "s": 2
    },
    "2": {
     "s": 2
    },
    "3": {
     "s": 2
    },
    "4": {
     "s": 2
    },
    "5": {
     "s": 4
    }
   },
   "10": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 8
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "11": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 9
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "12": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 10
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "13": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 11
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "14": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 12
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "15": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 13
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "16": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 14
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "17": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 15
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "18": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 16
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "19": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 17
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "2": {
    "0": {
     "s": 1
    },
    "1": {
     "s": 5,
     "v": "NO."
    },
    "2": {
     "s": 5,
     "v": "STATUS"
    },
    "3": {
     "s": 5,
     "v": "DATE"
    },
    "4": {
     "s": 6,
     "v": "TASK"
    },
    "5": {
     "s": 1
    }
   },
   "20": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 18
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "21": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 19
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "22": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 20
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "23": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 21
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "24": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 22
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "25": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 23
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "26": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 24
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "27": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 25
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "28": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 26
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "29": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 27
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "3": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 1
    },
    "2": {
     "s": 9,
     "v": "✓"
    },
    "3": {
     "s": 10,
     "v": 42668
    },
    "4": {
     "s": 11,
     "v": "Do laundry"
    },
    "5": {
     "s": 7
    }
   },
   "30": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 28
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "31": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 29
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "32": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 30
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "33": {
    "0": {
     "s": 8
    },
    "1": {
     "s": 8
    },
    "2": {
     "s": 8
    },
    "3": {
     "s": 8
    },
    "4": {
     "s": 8
    },
    "5": {
     "s": 8
    }
   },
   "4": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 2
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10,
     "v": 43401
    },
    "4": {
     "s": 11,
     "v": "See dentist"
    },
    "5": {
     "s": 7
    }
   },
   "5": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 3
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10,
     "v": 43404
    },
    "4": {
     "s": 11,
     "v": "Buy present for Mom"
    },
    "5": {
     "s": 7
    }
   },
   "6": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 4
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10,
     "v": 43419
    },
    "4": {
     "s": 11,
     "v": "Book flight tickets"
    },
    "5": {
     "s": 7
    }
   },
   "7": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 5
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10,
     "v": 43403
    },
    "4": {
     "s": 11,
     "v": "Wash car"
    },
    "5": {
     "s": 7
    }
   },
   "8": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 6
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   },
   "9": {
    "0": {
     "s": 7
    },
    "1": {
     "s": 9,
     "v": 7
    },
    "2": {
     "s": 9
    },
    "3": {
     "s": 10
    },
    "4": {
     "s": 11
    },
    "5": {
     "s": 7
    }
   }
  },
  "cfs": [
   {
    "cfId": "fb2b41aa9c69b704",
    "f1": "not(isblank($C4))",
    "ranges": [
     "B4:E33"
    ],
    "style": {
     "color": "b4b8bc",
     "strike": true
    },
    "type": "expression"
   }
  ],
  "colCount": 6,
  "cols": {
   "0": {
    "w": 24
   },
   "1": {
    "w": 48
   },
   "2": {
    "w": 80
   },
   "3": {
    "w": 100
   },
   "4": {
    "w": 400
   },
   "5": {
    "w": 24
   }
  },
  "drawing": [],
  "filter": {
   "range": null
  },
  "fixedColumnLeft": 0,
  "fixedRowTop": 3,
  "global": null,
  "mergeCells": [
   [
    1,
    1,
    1,
    4
   ],
   [
    0,
    1,
    0,
    3
   ],
   [
    0,
    5,
    1,
    5
   ],
   [
    0,
    0,
    1,
    0
   ],
   [
    33,
    1,
    33,
    4
   ]
  ],
  "rowCount": 34,
  "rows": {
   "0": {
    "h": 58
   },
   "1": {
    "h": 21
   },
   "10": {
    "h": 24
   },
   "11": {
    "h": 24
   },
   "12": {
    "h": 24
   },
   "13": {
    "h": 24
   },
   "14": {
    "h": 24
   },
   "15": {
    "h": 24
   },
   "16": {
    "h": 24
   },
   "17": {
    "h": 24
   },
   "18": {
    "h": 24
   },
   "19": {
    "h": 24
   },
   "2": {
    "h": 24
   },
   "20": {
    "h": 24
   },
   "21": {
    "h": 24
   },
   "22": {
    "h": 24
   },
   "23": {
    "h": 24
   },
   "24": {
    "h": 24
   },
   "25": {
    "h": 24
   },
   "26": {
    "h": 24
   },
   "27": {
    "h": 24
   },
   "28": {
    "h": 24
   },
   "29": {
    "h": 24
   },
   "3": {
    "h": 24
   },
   "30": {
    "h": 24
   },
   "31": {
    "h": 24
   },
   "32": {
    "h": 24
   },
   "33": {
    "h": 21
   },
   "4": {
    "h": 24
   },
   "5": {
    "h": 24
   },
   "6": {
    "h": 24
   },
   "7": {
    "h": 24
   },
   "8": {
    "h": 24
   },
   "9": {
    "h": 24
   }
  },
  "validation": {
   "12b55705678504dd": {
    "f1": "✓",
    "message": "",
    "operator": "list",
    "ranges": [
     "C4:C29",
     "C30",
     "C31",
     "C32",
     "C33"
    ],
    "reject": false,
    "type": "list",
    "validId": "12b55705678504dd"
   }
  }
 },
 "style": {
  "alignments": [
   {
    "h": "left",
    "v": "middle"
   },
   {
    "v": "middle",
    "w": "wrap"
   },
   {
    "h": "center",
    "v": "middle",
    "w": "wrap"
   },
   {
    "h": "left",
    "v": "bottom"
   },
   {
    "h": "right",
    "v": "bottom"
   },
   {
    "h": "left",
    "v": "middle",
    "w": "wrap"
   }
  ],
  "borders": [
   {
    "b": [
     null,
     null,
     "#1bb3a6",
     null
    ]
   },
   {
    "b": [
     null,
     "#1bb3a6",
     "#1bb3a6",
     null
    ]
   }
  ],
  "fills": [
   {
    "bg": "1bb3a6"
   }
  ],
  "fonts": [
   {
    "c": "ffffff",
    "sz": 23
   },
   {
    "c": "ffffff",
    "sz": 24
   },
   {
    "c": "ffffff",
    "n": "Trebuchet MS",
    "sz": 24
   },
   {
    "b": true,
    "c": "08998d",
    "n": "Trebuchet MS"
   },
   {
    "n": "Trebuchet MS",
    "sz": 10
   },
   {
    "c": "ffffff",
    "n": "Trebuchet MS",
    "sz": 12
   },
   {
    "c": "ffffff",
    "n": "Trebuchet MS",
    "sz": 23
   },
   {
    "n": "Arial",
    "sz": 10
   }
  ],
  "numberFormats": [
   {
    "fc": "M/d/yyyy"
   }
  ],
  "styles": [
   [
    2,
    0,
    0,
    2,
    0,
    0,
    0
   ],
   [
    4,
    1,
    1,
    1,
    0,
    0,
    0
   ],
   [
    2,
    0,
    1,
    0,
    0,
    0,
    0
   ],
   [
    2,
    2,
    1,
    1,
    0,
    0,
    0
   ],
   [
    3,
    4,
    0,
    3,
    0,
    0,
    0
   ],
   [
    1,
    4,
    0,
    2,
    0,
    0,
    0
   ],
   [
    60,
    5,
    0,
    2,
    0,
    0,
    0
   ],
   [
    6,
    7,
    1,
    1,
    0,
    0,
    0
   ],
   [
    60,
    8,
    0,
    3,
    0,
    0,
    0
   ],
   [
    30,
    8,
    0,
    3,
    0,
    1,
    0
   ],
   [
    30,
    8,
    0,
    6,
    0,
    0,
    0
   ],
   [
    2,
    3,
    1,
    4,
    1,
    0,
    0
   ],
   [
    1,
    6,
    1,
    5,
    1,
    0,
    0
   ],
   [
    1,
    3,
    1,
    4,
    2,
    0,
    0
   ]
  ]
 }
}
''';

Map<String, Object?> _decode(String raw) =>
    (jsonDecode(raw) as Map).cast<String, Object?>();

Map<String, Object?> _readEvidenceJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

/// 批 D 真实夹具（官方随包 `template/sheet/*/text.json` 逐字节复制，
/// bytes/sha256/出处见 `test/fixtures/office_templates/MANIFEST.json`）。
Map<String, Object?> _fixtureSections(String name) =>
    (jsonDecode(File('test/fixtures/office_templates/$name').readAsStringSync())
            as Map)
        .cast<String, Object?>();

TextStyle _cellTextStyle(WidgetTester tester, int r, int c) {
  final text = tester.widget<Text>(
    find.descendant(
      of: find.byKey(Key('office-sheet-cell-$r-$c')),
      matching: find.byType(Text),
    ),
  );
  return text.style!;
}

BoxDecoration _cellDecoration(WidgetTester tester, int r, int c) {
  final container = tester.widget<Container>(
    find.byKey(Key('office-sheet-cell-$r-$c')),
  );
  return container.decoration! as BoxDecoration;
}

Widget _host(
  Map<String, Object?> sections, [
  OfficeSheetRenderReport? report,
]) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: OfficeSheetView(sections: sections, report: report),
  ),
);

AlignmentGeometry? _cellAlignment(WidgetTester tester, int r, int c) {
  final container = tester.widget<Container>(
    find.byKey(Key('office-sheet-cell-$r-$c')),
  );
  return container.alignment;
}

void main() {
  final spikeSections = _decode(spikeSectionsJson);
  final todoSections = _decode(todoSectionsJson);

  group('S1. 命令词表 / section / 字段覆盖（schema 驱动，与机读证据逐字一致）', () {
    test('148 条命令 == sheet_commands.json 的 known_union', () {
      final doc = _readEvidenceJson(
        'tool/office_collab_spike/schema/sheet_commands.json',
      );
      final counts = (doc['counts'] as Map).cast<String, Object?>();
      expect(counts['known_union'], 148);
      final expected = <String>{
        ...(doc['all_cmd_literals'] as List).map((e) => '$e'),
        ...(doc['server_accepted_union'] as List).map((e) => '$e'),
      };
      expect(expected, hasLength(148));
      expect(
        kOfficeSheetCommandNames,
        expected,
        reason: 'kOfficeSheetCommands 的 key 必须逐字等于导出的 101 ∪ 141',
      );
      expect(kOfficeSheetCommands, hasLength(kOfficeSheetCommandWordCount));
    });

    test('29 个 dispatcher == sheet_commands.json 的 dispatchers', () {
      final doc = _readEvidenceJson(
        'tool/office_collab_spike/schema/sheet_commands.json',
      );
      final expected = (doc['dispatchers'] as List)
          .map((e) => '${(e as Map)['file']}@${e['offset']}')
          .toList();
      final actual = kOfficeSheetDispatchers
          .map((e) => '${e.file}@${e.offset}')
          .toList();
      expect(kOfficeSheetDispatchers, hasLength(kOfficeSheetDispatcherCount));
      expect(kOfficeSheetDispatchers, hasLength(29));
      expect(actual, expected);
    });

    test('命令证据带字段形状（value / worksheet.create）', () {
      expect(isOfficeSheetCommandKnown('value'), isTrue);
      expect(
        kOfficeSheetCommands['value']!.fieldKeys,
        containsAll(<String>['id', 'changes', 'source']),
      );
      expect(kOfficeSheetCommands['value']!.family, 'cell/block');
      expect(
        kOfficeSheetCommands['worksheet.create']!.fieldKeys,
        containsAll(<String>['pos', 'title', 'content']),
      );
      expect(kOfficeSheetCommands['worksheet.create']!.inServerSwitch, isTrue);
      expect(isOfficeSheetCommandKnown('definitely_not_a_command'), isFalse);
    });

    test('set ack 三态常量与真机原文一致', () {
      expect(kOfficeSheetSetAckShape, '(revIncoming, currentRev, status)');
      expect(kOfficeSheetSetStatusOk, 1);
      expect(kOfficeSheetSetStatusStaleRev, 2);
      expect(kOfficeSheetSetStatusRejected, 0);
      expect(kOfficeSheetCommentOnlyCommands, hasLength(5));
    });

    test('section ↔ "@C_text/" + section', () {
      expect(officeSheetSectionKey('sh_1'), '@C_text/sh_1');
      expect(officeSheetSectionKey('index'), '@C_text/index');
      expect(officeSheetSectionKey('locale'), '@C_text/locale');
    });

    test('section 覆盖度：index/style/sh_N 渲染，locale 登记，未知计数', () {
      expect(
        officeSheetSectionEvidence('index').support,
        OfficeSheetSectionSupport.rendered,
      );
      expect(
        officeSheetSectionEvidence('style').support,
        OfficeSheetSectionSupport.rendered,
      );
      expect(isOfficeSheetWorksheetSection('sh_7'), isTrue);
      expect(
        officeSheetSectionEvidence('sh_7').support,
        OfficeSheetSectionSupport.rendered,
      );
      expect(
        officeSheetSectionEvidence('locale').support,
        OfficeSheetSectionSupport.structural,
      );
      expect(
        officeSheetSectionEvidence('NOPE').support,
        OfficeSheetSectionSupport.unknown,
      );
    });

    test('字段登记表含真实样本的键', () {
      expect(
        kOfficeSheetWorksheetKeys,
        containsAll(<String>['cells', 'rows', 'cols']),
      );
      expect(kOfficeSheetCellKeys, containsAll(<String>['s', 'v', 'f']));
      expect(kOfficeSheetStyleKeys, contains('alignments'));
      expect(kOfficeSheetAlignmentKeys, containsAll(<String>['h', 'v', 'w']));
      expect(kOfficeSheetWorksheetPrefixCases, contains('create_with_data'));
    });
  });

  group('S2. 真机快照：网格 / 行列头 / 计数', () {
    testWidgets('渲染 C3SPIKE-SHEET-BASE，行列头与计数正确', (tester) async {
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(spikeSections, report));

      expect(find.byKey(const Key('office-sheet-view')), findsOneWidget);
      expect(find.text('C3SPIKE-SHEET-BASE'), findsOneWidget);
      expect(
        find.byKey(const Key('office-sheet-row-header-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-sheet-col-header-0')),
        findsOneWidget,
      );
      // 单表不显示 tab；真机快照的 6 个"登记但不进网格"的 section 只计数。
      expect(report.unknownSections, isEmpty);
      expect(report.unsupportedSections, isEmpty);
      expect(
        report.registeredOnlySections.keys,
        containsAll(<String>['locale', 'locale_info']),
      );
      expect(report.cellsRendered, 1);
      expect(report.formulaCells, 0);
      expect(report.hasDegradations, isFalse);
    });

    test('OSheetWorkbook 从 index 重建（schemaVersion=5, order=[sh_1]）', () {
      final workbook = OSheetWorkbook.fromSections(spikeSections);
      expect(workbook.sheets, hasLength(1));
      expect(workbook.sheets.first.id, 'sh_1');
      expect(workbook.sheets.first.title, 'C3Spike');
      expect(workbook.sheets.first.rowCount, 100);
      expect(workbook.sheets.first.colCount, 30);
      expect(workbook.sheets.first.cellAt(0, 0)?.value, 'C3SPIKE-SHEET-BASE');
    });
  });

  group('S3. 官方模板样本：文本 / 公式原样 / 对齐（证据驱动）', () {
    testWidgets('文本、公式（不求值）、数字都渲染', (tester) async {
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(todoSections, report));

      expect(find.text('TO-DO LIST'), findsOneWidget);
      // 公式：`v` 以 `=` 开头 → **原样显示**，本批不求值。
      expect(
        find.textContaining('=CONCATENATE(COUNTA(C4:C34)'),
        findsOneWidget,
      );
      expect(find.text('8'), findsWidgets);
      expect(report.formulaCells, 1);
      expect(report.mergedRanges, 5);
      expect(report.hiddenRows, 0);
    });

    testWidgets('水平对齐来自 style.styles[s-1][3] → alignments[id-1].h', (
      tester,
    ) async {
      await tester.pumpWidget(_host(todoSections));
      // (0,4) 公式：s=13 → styles[12]=[1,6,1,5,1,0,0] → alignment 5 → right。
      expect(_cellAlignment(tester, 0, 4), Alignment.centerRight);
      // (0,1) "TO-DO LIST"：s=12 → styles[11]=[2,3,1,4,1,0,0] → alignment 4 → left。
      expect(_cellAlignment(tester, 0, 1), Alignment.centerLeft);
      // (10,1) 数值 8：s=9 → styles[8]=[60,8,0,3,0,1,0] → alignment 3 → center。
      expect(_cellAlignment(tester, 10, 1), Alignment.center);
    });

    test('对齐解析器：越界 / s=0 / 无 h 都不崩', () {
      final workbook = OSheetWorkbook.fromSections(todoSections);
      final pool = workbook.styles;
      expect(officeSheetAlignmentH(pool, 13), 'right');
      expect(officeSheetAlignmentH(pool, 12), 'left');
      expect(officeSheetAlignmentH(pool, 0), isNull);
      expect(officeSheetAlignmentH(pool, 9999), isNull);
      expect(officeSheetAlignmentH(null, 13), isNull);
      // 数值无显式 h → 显示默认右对齐；文本无显式 h → 左对齐。
      expect(
        officeSheetCellAlign(pool: null, styleId: null, value: 42),
        OfficeSheetCellAlign.right,
      );
      expect(
        officeSheetCellAlign(pool: null, styleId: null, value: 'x'),
        OfficeSheetCellAlign.left,
      );
    });

    test('列标题 A1 记法', () {
      expect(officeSheetColumnLabel(0), 'A');
      expect(officeSheetColumnLabel(5), 'F');
      expect(officeSheetColumnLabel(25), 'Z');
      expect(officeSheetColumnLabel(26), 'AA');
      expect(officeSheetColumnLabel(27), 'AB');
      expect(officeSheetColumnLabel(51), 'AZ');
      expect(officeSheetColumnLabel(52), 'BA');
    });
  });

  group('S4. 未知 section / 字段 / 命令：可见降级 + 计数，不崩不静默', () {
    test('未知 section 进 report + 计数 + 部分降级横幅', () {
      final report = OfficeSheetRenderReport();
      final sections = <String, Object?>{
        ...spikeSections,
        'what_is_this': <String, Object?>{'x': 1},
      };
      scanOfficeSheetSections(sections, report);
      expect(report.unknownSections['what_is_this'], 1);
      expect(report.hasDegradations, isTrue);
      expect(report.degradationCount, 1);
      expect(report.messages.join('\n'), contains('@C_text/what_is_this'));
    });

    testWidgets('未知 section 仍然渲染网格（不崩、不静默）', (tester) async {
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(
        _host(<String, Object?>{
          ...spikeSections,
          'what_is_this': <String, Object?>{},
        }, report),
      );
      expect(find.text('C3SPIKE-SHEET-BASE'), findsOneWidget);
      expect(
        find.byKey(const Key('office-sheet-partial-banner')),
        findsOneWidget,
      );
      expect(report.unknownSections, contains('what_is_this'));
    });

    test('未知 index / sheet / cell / style 字段进 unknownFields', () {
      final report = OfficeSheetRenderReport();
      final sections = <String, Object?>{
        'index': <String, Object?>{
          'gcVer': 1,
          'order': <Object?>['sh_1'],
          'schemaVersion': 5,
          'sheets': <String, Object?>{
            'sh_1': <String, Object?>{'title': 'T', 'mysteryField': true},
          },
          'ver': 1,
          'surprise': 1,
        },
        'style': <String, Object?>{
          'styles': <Object?>[],
          'fonts': <Object?>[],
          'secretPool': <Object?>[],
        },
        'sh_1': <String, Object?>{
          'rowCount': 1,
          'colCount': 1,
          'weird': 2,
          'cells': <String, Object?>{
            '0': <String, Object?>{
              '0': <String, Object?>{'v': 'x', 'unheardOf': 1},
            },
          },
        },
      };
      scanOfficeSheetSections(sections, report);
      expect(
        report.unknownFields.keys,
        containsAll(<String>[
          'index.surprise',
          'index.sheets.mysteryField',
          'style.secretPool',
          'sh_1.weird',
          'sh_1.cell.unheardOf',
        ]),
      );
      expect(report.hasDegradations, isTrue);
    });

    test('init commands[]：不回放、认识/不认识都登记、缺 cmd 计数', () {
      final report = OfficeSheetRenderReport();
      scanOfficeSheetCommands(
        <Object?>[
          <String, Object?>{'cmd': 'value', 'changes': <Object?>[]},
          <String, Object?>{'cmd': 'totally_unknown_cmd'},
          <String, Object?>{'not_cmd': 1},
        ],
        report,
        source: 'test',
      );
      expect(report.commandsNotReplayed, 3);
      expect(report.seenCommands['value'], 1);
      expect(report.seenCommands['totally_unknown_cmd'], 1);
      expect(report.unknownCommands['totally_unknown_cmd'], 1);
      expect(report.malformedCommands, 1);
      expect(report.hasDegradations, isTrue);
    });

    test('空 / 坏数据不崩（坏 cells 类型 → 空网格卡片）', () {
      final report = OfficeSheetRenderReport();
      scanOfficeSheetSections(const <String, Object?>{}, report);
      expect(report.hasDegradations, isFalse);
    });

    testWidgets('空 section 字典 → empty 卡片（不崩）', (tester) async {
      await tester.pumpWidget(_host(const <String, Object?>{}));
      expect(find.byKey(const Key('office-sheet-empty')), findsOneWidget);
    });

    testWidgets('坏 cells（字符串而非 map）→ 不崩', (tester) async {
      await tester.pumpWidget(
        _host(<String, Object?>{
          'index': <String, Object?>{
            'order': <Object?>['sh_1'],
            'schemaVersion': 5,
            'sheets': <String, Object?>{
              'sh_1': <String, Object?>{'title': 'Broken'},
            },
            'ver': 1,
          },
          'style': <String, Object?>{'styles': <Object?>[]},
          'sh_1': <String, Object?>{
            'rowCount': 2,
            'colCount': 2,
            'cells': 'not a map',
          },
        }),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('office-sheet-grid')), findsOneWidget);
    });
  });

  group('D6. 真实 .osheet 夹具：合并 / 样式解引用 / 公式 / 条件格式', () {
    final todo = _fixtureSections('sheet_to_do_list_simple.json');

    testWidgets('mergeCells [r1,c1,r2,c2] → 只画一个大格，被覆盖的格不画', (tester) async {
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(todo, report));
      // [0,1,0,3] 的锚点 B1 存在，且宽度 = 48 + 80 + 100（B/C/D 三列宽之和）。
      final anchor = find.byKey(const Key('office-sheet-cell-0-1'));
      expect(anchor, findsOneWidget);
      expect(tester.getSize(anchor).width, 228);
      // C1 / D1 是被覆盖格 → **不存在**（不是画成两个小格）。
      expect(find.byKey(const Key('office-sheet-cell-0-2')), findsNothing);
      expect(find.byKey(const Key('office-sheet-cell-0-3')), findsNothing);
      // [0,0,1,0] 是**行区间**合并：A1 高度 = 58 + 21。
      expect(
        tester.getSize(find.byKey(const Key('office-sheet-cell-0-0'))).height,
        79,
      );
      expect(find.byKey(const Key('office-sheet-cell-1-0')), findsNothing);
      // [0,5,1,5]：F1 跨两行。
      expect(
        tester.getSize(find.byKey(const Key('office-sheet-cell-0-5'))).height,
        79,
      );
      expect(find.byKey(const Key('office-sheet-cell-1-5')), findsNothing);
      expect(report.mergedRanges, 5);
      expect(report.mergedCellsRendered, 5);
    });

    testWidgets('样式表解引用：字体色/字号/填充/边框都来自子表（不是 styles[i]）', (tester) async {
      await tester.pumpWidget(_host(todo));
      // (0,1) "TO-DO LIST"：s=12 → fonts[2]（ffffff/24）+ fills[0]（1bb3a6）
      final textStyle = _cellTextStyle(tester, 0, 1);
      expect(textStyle.color, const Color(0xFFFFFFFF));
      expect(textStyle.fontSize, 24);
      expect(textStyle.fontFamily, 'Trebuchet MS');
      final decoration = _cellDecoration(tester, 0, 1);
      expect(decoration.color, const Color(0xFF1BB3A6));
      expect(decoration.border, isA<Border>());
      expect(
        (decoration.border! as Border).bottom.color,
        const Color(0xFF1BB3A6),
      );
      // 批 D 起四个样式池不再登记为 unrendered。
      final report = OfficeSheetRenderReport();
      scanOfficeSheetSections(todo, report);
      expect(report.unrenderedStyleFacets, isEmpty);
      expect(
        report.resolvedStyleFacets,
        containsAll(<String>[
          'fonts',
          'fills',
          'alignments',
          'borders',
          'numberFormats',
        ]),
      );
      expect(report.numberFormatsResolved, 1);
    });

    testWidgets('不支持的函数（CONCATENATE）→ 退化显示公式原文（不假装算出结果）', (tester) async {
      await tester.pumpWidget(_host(todo));
      final formula = find.byKey(const Key('office-sheet-formula-0-4'));
      expect(formula, findsOneWidget);
      expect(
        tester.widget<Text>(formula).data,
        '=CONCATENATE(COUNTA(C4:C34), "/", COUNTA(E4:E34), " Completed  ")',
      );
      expect(
        find.textContaining('=CONCATENATE(COUNTA(C4:C34)'),
        findsOneWidget,
      );
    });

    testWidgets('cfs 条件格式：按 ranges 套 color/strike；f1 原样展示不求值', (tester) async {
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(todo, report));
      // B4:E33 内、(3,1) 命中 cfs（color b4b8bc + strike）。
      final hit = _cellTextStyle(tester, 3, 1);
      expect(hit.color, const Color(0xFFB4B8BC));
      expect(hit.decoration, TextDecoration.lineThrough);
      // 范围外（C1 行 0 不在 B4:E33）不叠加。
      final miss = _cellTextStyle(tester, 0, 1);
      expect(miss.color, isNot(const Color(0xFFB4B8BC)));
      // 条件公式 `f1` 原文可见（未求值）。
      expect(find.byKey(const Key('office-sheet-cfs-note')), findsOneWidget);
      expect(find.textContaining('not(isblank(\$C4))'), findsOneWidget);
      expect(report.conditionalFormats, 1);
      expect(report.conditionalCellsStyled, greaterThan(0));
    });

    testWidgets('expense_report（51 处合并、无 cfs）真实夹具整页渲染', (tester) async {
      final sections = _fixtureSections('sheet_expense_report.json');
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(sections, report));
      expect(find.byKey(const Key('office-sheet-view')), findsOneWidget);
      expect(report.mergedRanges, 51);
      expect(report.mergedCellsRendered, 51);
      expect(report.conditionalFormats, 0);
      expect(find.byKey(const Key('office-sheet-cfs-note')), findsNothing);
      // 至少有一个真实合并锚点被画成大格（第一个区间 B2:E2 → 宽 > 单列）。
      expect(
        tester.getSize(find.byKey(const Key('office-sheet-cell-1-1'))).width,
        greaterThan(108),
      );
    });

    testWidgets('to_do_list_professional：两张表 + 3 条条件格式（真实多表）', (tester) async {
      final sections = _fixtureSections('sheet_to_do_list_professional.json');
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(sections, report));
      expect(find.byKey(const Key('office-sheet-tab-sh_1')), findsOneWidget);
      expect(find.byKey(const Key('office-sheet-tab-sh_2')), findsOneWidget);
      // 报告是**工作簿级**：sh_1 + sh_2 各 3 条 = 6。
      expect(report.conditionalFormats, 6);
      expect(find.byKey(const Key('office-sheet-cfs-note')), findsOneWidget);
      await tester.tap(find.byKey(const Key('office-sheet-tab-sh_2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-sheet-cfs-note')), findsOneWidget);
    });

    testWidgets('drawing 非空（真实 chart bar+pie）→ **真的画出来**（O3 起）', (
      tester,
    ) async {
      final sections = _fixtureSections('sheet_sales_tracker.json');
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(sections, report));
      // 真实样本有 2 个 chart：barChart + pieChart，两个都能画。
      expect(report.chartsRendered, 2);
      expect(report.unsupportedDrawingItems, 0);
      // 真的画笔（不是占位卡）。
      final barPaint = tester.widget<CustomPaint>(
        find.byKey(const Key('office-sheet-chart-paint-c8e98ec07208261d')),
      );
      final painter = barPaint.painter! as OfficeSheetChartPainter;
      expect(painter.kind, OfficeSheetChartKind.bar);
      expect(painter.title, 'Product Profit Per Item');
      expect(painter.data.categories.length, 5);
      expect(
        find.byKey(const Key('office-sheet-chart-c8e98ec07208261d')),
        findsNothing,
        reason: '可绘制的图表**不再**退回占位卡',
      );
      final piePaint = tester.widget<CustomPaint>(
        find.byKey(const Key('office-sheet-chart-paint-88650364051df188')),
      );
      expect(
        (piePaint.painter! as OfficeSheetChartPainter).kind,
        OfficeSheetChartKind.pie,
      );
    });

    testWidgets('filter.range 非空 → 登记为未实现（不崩）', (tester) async {
      final report = OfficeSheetRenderReport();
      final sections = <String, Object?>{
        ...spikeSections,
        'sh_1': <String, Object?>{
          ...(spikeSections['sh_1']! as Map).cast<String, Object?>(),
          'filter': <String, Object?>{
            'range': <Object?>[3, 1, 48, 12],
          },
          'rowCount': 1,
          'colCount': 1,
          'cells': <String, Object?>{
            '0': <String, Object?>{
              '0': <String, Object?>{'v': 'x'},
            },
          },
          'rows': <String, Object?>{},
          'cols': <String, Object?>{},
          'mergeCells': <Object?>[],
          'cfs': <Object?>[],
          'drawing': <Object?>[],
        },
      };
      await tester.pumpWidget(_host(sections, report));
      expect(report.unsupportedFilterRanges, 1);
      expect(report.hasDegradations, isTrue);
      expect(find.text('x'), findsOneWidget);
    });
  });
}
