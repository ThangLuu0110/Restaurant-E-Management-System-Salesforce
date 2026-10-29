/**
 * Trigger duy nhất cho Order_Item__c (one trigger per object).
 * Chỉ dispatch sang Handler, không chứa logic nghiệp vụ.
 */
trigger OrderItemTrigger on Order_Item__c(
    before insert,
    before update,
    before delete,
    after insert,
    after update,
    after delete
) {
    if (Trigger.isBefore) {
        if (Trigger.isInsert)
            OrderItemTriggerHandler.beforeInsert(Trigger.new);
        if (Trigger.isUpdate)
            OrderItemTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
        if (Trigger.isDelete)
            OrderItemTriggerHandler.beforeDelete(Trigger.old);
    }
    if (Trigger.isAfter) {
        if (Trigger.isInsert)
            OrderItemTriggerHandler.afterInsert(Trigger.new);
        if (Trigger.isUpdate)
            OrderItemTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
        if (Trigger.isDelete)
            OrderItemTriggerHandler.afterDelete(Trigger.old);
    }
}
