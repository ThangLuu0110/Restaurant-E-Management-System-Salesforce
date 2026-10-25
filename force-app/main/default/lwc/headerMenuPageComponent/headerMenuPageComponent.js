import { LightningElement, api, wire } from "lwc";
import { CurrentPageReference } from "lightning/navigation";

export default class HeaderMenuPageComponent extends LightningElement {
  @api title;
  tableId;

  @wire(CurrentPageReference)
  setPageRef(pageRef) {
    this.tableId = pageRef?.state?.tableId;
  }
}
