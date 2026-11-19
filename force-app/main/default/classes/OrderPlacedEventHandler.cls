/**
 * Xử lý Order_Placed__e: gắn các món khách gửi từ trang menu vào đơn của bàn.
 *
 * - Bàn chưa có đơn đang mở (Current_Order__c trống hoặc đơn đã Paid /
 *   Canceled): tạo Order_Request__c (Placed) mới và gắn vào
 *   Table__c.Current_Order__c.
 * - Bàn đã có đơn đang mở: thêm Order_Item__c (Pending) vào đơn đó (gọi thêm
 *   món). Đơn đang Ready / Served được đưa về Placed để bếp biết có món mới.
 * - Nhiều event của cùng 1 bàn trong 1 batch dùng chung 1 đơn.
 * - Chạy bằng Automated Process user, without sharing để không phụ thuộc vào
 *   sharing của bản ghi (giống mọi trigger chạy ở system mode).
 * - Kiểm tra lại dữ liệu vì trạng thái món có thể đổi sau khi khách gửi đơn.
 * - Mỗi lần gửi là tất cả hoặc không: chỉ 1 món lỗi thì mọi món của lần gửi
 *   đó bị huỷ, các món đã gọi trước đó vẫn giữ nguyên. Đơn mới không còn món
 *   nào thì bị xoá. Lỗi chỉ ghi Order_Error_Log__c để admin xem, các event
 *   khác trong cùng batch vẫn được xử lý.
 * - Bulk-safe: số SOQL/DML cố định, không phụ thuộc số lượng event.
 */
public without sharing class OrderPlacedEventHandler {
  @TestVisible
  private static final String ERROR_INVALID_PAYLOAD = 'Dữ liệu đơn không đọc được: ';
  @TestVisible
  private static final String ERROR_TABLE_NOT_FOUND = 'Không tìm thấy bàn.';
  @TestVisible
  private static final String ERROR_EMPTY_ORDER = 'Đơn không có món nào.';
  @TestVisible
  private static final String ERROR_INVALID_QUANTITY = 'Có món với số lượng không hợp lệ.';
  @TestVisible
  private static final String ERROR_ITEM_UNAVAILABLE = 'Món đã hết hoặc không tồn tại: ';
  @TestVisible
  private static final String ERROR_INSERT_ORDER = 'Không tạo được Order_Request__c: ';
  @TestVisible
  private static final String ERROR_INSERT_ITEM = 'Không tạo được Order_Item__c, đơn đã bị huỷ: ';
  @TestVisible
  private static final String ERROR_INSERT_ADDED_ITEM = 'Không thêm được món vào đơn, các món của lần gọi này đã bị huỷ: ';
  @TestVisible
  private static final String ERROR_UPDATE_TABLE = 'Không cập nhật được Current_Order__c cho bàn: ';
  @TestVisible
  private static final String ERROR_REOPEN_ORDER = 'Không đưa được đơn về Placed sau khi gọi thêm: ';

  /** Đơn ở trạng thái này coi như đã đóng, lần gọi tiếp theo tạo đơn mới. */
  @TestVisible
  private static final Set<String> CLOSED_ORDER_STATUSES = new Set<String>{
    'Paid',
    'Canceled'
  };
  /** Đơn ở trạng thái này được đưa về Placed khi khách gọi thêm món. */
  private static final Set<String> REOPEN_ORDER_STATUSES = new Set<String>{
    'Ready',
    'Served'
  };

  private static final String ORDER_STATUS_PLACED = 'Placed';
  private static final String ITEM_STATUS_PENDING = 'Pending';
  private static final Integer PAYLOAD_MAX_LENGTH = 131072;
  private static final Integer MESSAGE_MAX_LENGTH = 32768;

  /** Một lần gửi món đang xử lý: event gốc cùng dữ liệu đã đọc được. */
  private class PendingOrder {
    Order_Placed__e event;
    Id tableId;
    List<OrderService.OrderItemWrapper> items;
    // Đơn mà các món được gắn vào. Các lần gửi của cùng 1 bàn dùng chung
    // 1 instance nên Id gán sau khi insert được thấy ở tất cả.
    Order_Request__c order;
    // true: lần gửi này tạo Order_Request__c mới; false: gọi thêm vào đơn có sẵn
    Boolean createsOrder = false;
    // Status__c của đơn có sẵn, dùng để quyết định có đưa về Placed hay không
    String existingStatus;
    Boolean failed = false;
  }

  public static void handle(List<Order_Placed__e> events) {
    List<Order_Error_Log__c> logs = new List<Order_Error_Log__c>();

    List<PendingOrder> pendingOrders = parseEvents(events, logs);
    Map<Id, Table__c> tableById = queryTables(pendingOrders);
    List<PendingOrder> validOrders = validate(pendingOrders, tableById, logs);
    List<PendingOrder> assignedOrders = assignOrders(
      validOrders,
      tableById,
      logs
    );
    insertOrderItems(assignedOrders, logs);
    reopenOrders(assignedOrders, logs);

    if (!logs.isEmpty()) {
      Database.insert(logs, false);
    }
  }

  // ---------- 1. Đọc dữ liệu event ----------

  private static List<PendingOrder> parseEvents(
    List<Order_Placed__e> events,
    List<Order_Error_Log__c> logs
  ) {
    List<PendingOrder> pendingOrders = new List<PendingOrder>();
    for (Order_Placed__e event : events) {
      PendingOrder pending = new PendingOrder();
      pending.event = event;
      try {
        pending.tableId = Id.valueOf(event.Table_Id__c);
        pending.items = (List<OrderService.OrderItemWrapper>) JSON.deserialize(
          event.Items_JSON__c,
          List<OrderService.OrderItemWrapper>.class
        );
      } catch (Exception e) {
        logs.add(buildLog(event, ERROR_INVALID_PAYLOAD + e.getMessage()));
        continue;
      }
      pendingOrders.add(pending);
    }
    return pendingOrders;
  }

  // ---------- 2. Kiểm tra bàn, số lượng và tình trạng món ----------

  /** Bàn kèm đơn hiện tại, đọc lúc xử lý event để có trạng thái mới nhất. */
  private static Map<Id, Table__c> queryTables(
    List<PendingOrder> pendingOrders
  ) {
    Set<Id> tableIds = new Set<Id>();
    for (PendingOrder pending : pendingOrders) {
      tableIds.add(pending.tableId);
    }
    return new Map<Id, Table__c>(
      [
        SELECT Id, Current_Order__c, Current_Order__r.Status__c
        FROM Table__c
        WHERE Id IN :tableIds
      ]
    );
  }

  private static List<PendingOrder> validate(
    List<PendingOrder> pendingOrders,
    Map<Id, Table__c> tableById,
    List<Order_Error_Log__c> logs
  ) {
    Set<Id> menuItemIds = new Set<Id>();
    for (PendingOrder pending : pendingOrders) {
      for (OrderService.OrderItemWrapper item : nullSafe(pending.items)) {
        if (item != null && item.menuItemId != null) {
          menuItemIds.add(item.menuItemId);
        }
      }
    }
    Map<Id, Menu_Item__c> menuById = new Map<Id, Menu_Item__c>(
      [
        SELECT Id, Name, Is_Available__c
        FROM Menu_Item__c
        WHERE Id IN :menuItemIds
      ]
    );

    List<PendingOrder> validOrders = new List<PendingOrder>();
    for (PendingOrder pending : pendingOrders) {
      String error = findError(pending, tableById.keySet(), menuById);
      if (error == null) {
        validOrders.add(pending);
      } else {
        logs.add(buildLog(pending.event, error));
      }
    }
    return validOrders;
  }

  /** Trả về lý do lỗi đầu tiên của lần gửi, null nếu hợp lệ. */
  private static String findError(
    PendingOrder pending,
    Set<Id> existingTableIds,
    Map<Id, Menu_Item__c> menuById
  ) {
    if (!existingTableIds.contains(pending.tableId)) {
      return ERROR_TABLE_NOT_FOUND;
    }
    if (pending.items == null || pending.items.isEmpty()) {
      return ERROR_EMPTY_ORDER;
    }
    for (OrderService.OrderItemWrapper item : pending.items) {
      if (item == null || item.quantity == null || item.quantity <= 0) {
        return ERROR_INVALID_QUANTITY;
      }
      Menu_Item__c menuItem = menuById.get(item.menuItemId);
      if (menuItem == null || !menuItem.Is_Available__c) {
        return ERROR_ITEM_UNAVAILABLE +
          (menuItem != null ? menuItem.Name : String.valueOf(item.menuItemId));
      }
    }
    return null;
  }

  // ---------- 3. Chọn đơn: dùng đơn đang mở của bàn hoặc tạo đơn mới ----------

  private static List<PendingOrder> assignOrders(
    List<PendingOrder> validOrders,
    Map<Id, Table__c> tableById,
    List<Order_Error_Log__c> logs
  ) {
    Map<Id, Order_Request__c> orderByTable = new Map<Id, Order_Request__c>();
    List<PendingOrder> creators = new List<PendingOrder>();
    for (PendingOrder pending : validOrders) {
      Order_Request__c order = orderByTable.get(pending.tableId);
      if (order == null) {
        Table__c table = tableById.get(pending.tableId);
        if (hasOpenOrder(table)) {
          order = new Order_Request__c(Id = table.Current_Order__c);
        } else {
          order = new Order_Request__c(
            Table__c = pending.tableId,
            Status__c = ORDER_STATUS_PLACED,
            Order_Time__c = pending.event.CreatedDate != null
              ? pending.event.CreatedDate
              : System.now()
          );
          pending.createsOrder = true;
          creators.add(pending);
        }
        orderByTable.put(pending.tableId, order);
      }
      pending.order = order;
      // Lúc này chỉ đơn có sẵn mới có Id (đơn mới chưa được insert)
      if (order.Id != null) {
        pending.existingStatus = tableById.get(pending.tableId)
          .Current_Order__r.Status__c;
      }
    }

    Map<Id, String> insertErrorByTable = insertNewOrders(creators, logs);

    List<PendingOrder> assignedOrders = new List<PendingOrder>();
    for (PendingOrder pending : validOrders) {
      if (pending.order.Id != null) {
        assignedOrders.add(pending);
      } else {
        logs.add(
          buildLog(
            pending.event,
            ERROR_INSERT_ORDER + insertErrorByTable.get(pending.tableId)
          )
        );
      }
    }
    return assignedOrders;
  }

  private static Boolean hasOpenOrder(Table__c table) {
    return table.Current_Order__c != null &&
      !CLOSED_ORDER_STATUSES.contains(table.Current_Order__r.Status__c);
  }

  /** Insert đơn mới, trả về lỗi theo bàn cho các đơn không tạo được. */
  private static Map<Id, String> insertNewOrders(
    List<PendingOrder> creators,
    List<Order_Error_Log__c> logs
  ) {
    Map<Id, String> errorByTable = new Map<Id, String>();
    if (creators.isEmpty()) {
      return errorByTable;
    }
    List<Order_Request__c> orders = new List<Order_Request__c>();
    for (PendingOrder pending : creators) {
      orders.add(pending.order);
    }

    List<PendingOrder> created = new List<PendingOrder>();
    List<Database.SaveResult> results = Database.insert(orders, false);
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        created.add(creators[i]);
      } else {
        errorByTable.put(
          creators[i].tableId,
          joinErrors(results[i].getErrors())
        );
      }
    }
    updateTableCurrentOrder(created, logs);
    return errorByTable;
  }

  /** Gắn Order_Request__c vừa tạo vào Table__c.Current_Order__c tương ứng. */
  private static void updateTableCurrentOrder(
    List<PendingOrder> created,
    List<Order_Error_Log__c> logs
  ) {
    if (created.isEmpty()) {
      return;
    }
    List<Table__c> tables = new List<Table__c>();
    for (PendingOrder pending : created) {
      tables.add(
        new Table__c(Id = pending.tableId, Current_Order__c = pending.order.Id)
      );
    }
    List<Database.SaveResult> results = Database.update(tables, false);
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        logs.add(
          buildLog(
            created[i].event,
            ERROR_UPDATE_TABLE + joinErrors(results[i].getErrors())
          )
        );
      }
    }
  }

  // ---------- 4. Tạo Order_Item__c, huỷ lần gửi nếu có món lỗi ----------

  private static void insertOrderItems(
    List<PendingOrder> assignedOrders,
    List<Order_Error_Log__c> logs
  ) {
    List<Order_Item__c> orderItems = new List<Order_Item__c>();
    List<Integer> ownerIndex = new List<Integer>();
    for (Integer p = 0; p < assignedOrders.size(); p++) {
      PendingOrder pending = assignedOrders[p];
      for (OrderService.OrderItemWrapper item : pending.items) {
        orderItems.add(
          new Order_Item__c(
            Order__c = pending.order.Id,
            Menu_Item__c = item.menuItemId,
            Quantity__c = item.quantity,
            Special_Instructions__c = String.isBlank(item.specialInstructions)
              ? null
              : item.specialInstructions.trim(),
            Status__c = ITEM_STATUS_PENDING
          )
        );
        ownerIndex.add(p);
      }
    }
    if (orderItems.isEmpty()) {
      return;
    }

    // Gom kết quả theo lần gửi: 1 lần gửi chỉ ghi 1 log dù nhiều món lỗi
    Map<Integer, List<Id>> insertedIdsByOwner = new Map<Integer, List<Id>>();
    Map<Integer, List<String>> errorsByOwner = new Map<Integer, List<String>>();
    List<Database.SaveResult> results = Database.insert(orderItems, false);
    for (Integer i = 0; i < results.size(); i++) {
      Integer owner = ownerIndex[i];
      if (results[i].isSuccess()) {
        if (!insertedIdsByOwner.containsKey(owner)) {
          insertedIdsByOwner.put(owner, new List<Id>());
        }
        insertedIdsByOwner.get(owner).add(results[i].getId());
      } else {
        if (!errorsByOwner.containsKey(owner)) {
          errorsByOwner.put(owner, new List<String>());
        }
        errorsByOwner.get(owner).add(joinErrors(results[i].getErrors()));
      }
    }
    if (errorsByOwner.isEmpty()) {
      return;
    }

    // Huỷ mọi món của lần gửi bị lỗi, giữ nguyên món của các lần gửi khác
    List<Order_Item__c> itemsToDelete = new List<Order_Item__c>();
    for (Integer owner : errorsByOwner.keySet()) {
      assignedOrders[owner].failed = true;
      for (Id itemId : nullSafeIds(insertedIdsByOwner.get(owner))) {
        itemsToDelete.add(new Order_Item__c(Id = itemId));
      }
    }
    if (!itemsToDelete.isEmpty()) {
      Database.delete(itemsToDelete, false);
    }

    // Đơn mới tạo mà không còn lần gửi nào thành công thì xoá đơn
    // (Current_Order__c của bàn tự về null vì lookup là SetNull)
    Set<Id> keptOrderIds = new Set<Id>();
    for (PendingOrder pending : assignedOrders) {
      if (!pending.failed) {
        keptOrderIds.add(pending.order.Id);
      }
    }
    Map<Id, Order_Request__c> ordersToDelete = new Map<Id, Order_Request__c>();
    for (PendingOrder pending : assignedOrders) {
      if (pending.createsOrder && !keptOrderIds.contains(pending.order.Id)) {
        ordersToDelete.put(
          pending.order.Id,
          new Order_Request__c(Id = pending.order.Id)
        );
      }
    }
    if (!ordersToDelete.isEmpty()) {
      Database.delete(ordersToDelete.values(), false);
    }

    for (Integer owner : errorsByOwner.keySet()) {
      PendingOrder pending = assignedOrders[owner];
      String errors = String.join(errorsByOwner.get(owner), '; ');
      logs.add(
        buildLog(
          pending.event,
          (ordersToDelete.containsKey(pending.order.Id)
            ? ERROR_INSERT_ITEM
            : ERROR_INSERT_ADDED_ITEM) + errors
        )
      );
    }
  }

  // ---------- 5. Đưa đơn Ready / Served về Placed khi có món gọi thêm ----------

  private static void reopenOrders(
    List<PendingOrder> assignedOrders,
    List<Order_Error_Log__c> logs
  ) {
    Map<Id, PendingOrder> pendingByOrderId = new Map<Id, PendingOrder>();
    for (PendingOrder pending : assignedOrders) {
      if (
        !pending.failed &&
        REOPEN_ORDER_STATUSES.contains(pending.existingStatus) &&
        !pendingByOrderId.containsKey(pending.order.Id)
      ) {
        pendingByOrderId.put(pending.order.Id, pending);
      }
    }
    if (pendingByOrderId.isEmpty()) {
      return;
    }

    List<Order_Request__c> orders = new List<Order_Request__c>();
    List<PendingOrder> owners = pendingByOrderId.values();
    for (PendingOrder pending : owners) {
      orders.add(
        new Order_Request__c(
          Id = pending.order.Id,
          Status__c = ORDER_STATUS_PLACED
        )
      );
    }
    List<Database.SaveResult> results = Database.update(orders, false);
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        logs.add(
          buildLog(
            owners[i].event,
            ERROR_REOPEN_ORDER + joinErrors(results[i].getErrors())
          )
        );
      }
    }
  }

  // ---------- Tiện ích ----------

  private static List<OrderService.OrderItemWrapper> nullSafe(
    List<OrderService.OrderItemWrapper> items
  ) {
    return items == null ? new List<OrderService.OrderItemWrapper>() : items;
  }

  private static List<Id> nullSafeIds(List<Id> ids) {
    return ids == null ? new List<Id>() : ids;
  }

  private static String joinErrors(List<Database.Error> errors) {
    List<String> messages = new List<String>();
    for (Database.Error error : errors) {
      messages.add(error.getStatusCode() + ': ' + error.getMessage());
    }
    return String.join(messages, ', ');
  }

  private static Order_Error_Log__c buildLog(
    Order_Placed__e event,
    String message
  ) {
    return new Order_Error_Log__c(
      Table_Id__c = event.Table_Id__c == null
        ? null
        : event.Table_Id__c.left(18),
      Payload__c = event.Items_JSON__c == null
        ? null
        : event.Items_JSON__c.left(PAYLOAD_MAX_LENGTH),
      Error_Message__c = message.left(MESSAGE_MAX_LENGTH),
      Event_Replay_Id__c = event.ReplayId
    );
  }
}
