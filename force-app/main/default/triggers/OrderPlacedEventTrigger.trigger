/**
 * Nhận đơn khách gửi từ trang menu. Chạy bằng Automated Process user nên
 * tạo được Order_Request__c và Order_Item__c (guest không tạo được bản ghi
 * con Master-Detail). Chỉ dispatch sang Handler.
 */
trigger OrderPlacedEventTrigger on Order_Placed__e(after insert) {
  OrderPlacedEventHandler.handle(Trigger.new);
}
