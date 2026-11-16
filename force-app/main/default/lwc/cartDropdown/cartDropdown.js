import { LightningElement, api } from "lwc";

// Định dạng tiền kiểu 50.000đ
export function formatPrice(value) {
  const amount = Number(value) || 0;
  return `${new Intl.NumberFormat("vi-VN").format(amount)}đ`;
}

/**
 * Dropdown giỏ hàng: chỉ hiển thị dữ liệu nhận từ component cha.
 * Mọi thay đổi được báo lên cha qua event:
 *  - quantitychange: { id, quantity }
 *  - remove: { id }
 *  - clear
 */
export default class CartDropdown extends LightningElement {
  @api items = []; // [{ id, name, price, imageSrc, quantity }]

  get isEmpty() {
    return !this.items || this.items.length === 0;
  }

  get hasItems() {
    return !this.isEmpty;
  }

  get rows() {
    return (this.items || []).map((item) => ({
      ...item,
      priceLabel: formatPrice(item.price),
      lineTotalLabel: formatPrice(item.price * item.quantity),
      decreaseLabel: `Giảm số lượng ${item.name}`,
      increaseLabel: `Tăng số lượng ${item.name}`,
      removeLabel: `Xóa ${item.name} khỏi giỏ`
    }));
  }

  get totalLabel() {
    const total = (this.items || []).reduce(
      (sum, item) => sum + item.price * item.quantity,
      0
    );
    return formatPrice(total);
  }

  findItem(id) {
    return (this.items || []).find((item) => item.id === id);
  }

  handleDecrease(event) {
    const item = this.findItem(event.currentTarget.dataset.id);
    if (item) {
      this.fireQuantityChange(item.id, item.quantity - 1);
    }
  }

  handleIncrease(event) {
    const item = this.findItem(event.currentTarget.dataset.id);
    if (item) {
      this.fireQuantityChange(item.id, item.quantity + 1);
    }
  }

  handleRemove(event) {
    this.dispatchEvent(
      new CustomEvent("remove", {
        detail: { id: event.currentTarget.dataset.id }
      })
    );
  }

  handleClear() {
    this.dispatchEvent(new CustomEvent("clear"));
  }

  fireQuantityChange(id, quantity) {
    this.dispatchEvent(
      new CustomEvent("quantitychange", { detail: { id, quantity } })
    );
  }
}
