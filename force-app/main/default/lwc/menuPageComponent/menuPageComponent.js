import { LightningElement, api, wire } from "lwc";
import { CurrentPageReference } from "lightning/navigation";
import getMenuItems from "@salesforce/apex/MenuController.getMenuItems";
import getCategoryOptions from "@salesforce/apex/MenuController.getCategoryOptions";
import getTableIdByNumber from "@salesforce/apex/MenuController.getTableIdByNumber";
import placeOrder from "@salesforce/apex/OrderService.placeOrder";
import FOOD_IMAGES from "@salesforce/resourceUrl/FoodImages";
import { formatPrice, NOTE_MAX_LENGTH } from "c/cartDropdown";

const FOLDER = "food-images";
const SEARCH_DELAY_MS = 300;
const TOAST_DURATION_MS = 2500;
const ERROR_TOAST_DURATION_MS = 5000;
const DEFAULT_ORDER_ERROR = "Đặt hàng không thành công, vui lòng thử lại.";
const CART_STORAGE_KEY = "rems_cart";
const TABLE_NUMBER_PATTERN = /^\d{1,10}$/;

// Chuẩn hóa chuỗi để so sánh: chữ thường, bỏ dấu tiếng Việt, bỏ khoảng trắng đầu/cuối
function normalizeText(value) {
  return (value || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/đ/g, "d")
    .trim();
}

export default class MenuPageComponent extends LightningElement {
  @api title;
  @api item; // Menu_Item__c record
  categoryOptions = [];
  selectedCategory = "All";
  allMenuItems = [];
  searchKey = ""; // từ khóa đã chuẩn hóa
  searchTimeout;
  error;

  // Giỏ hàng: [{ id, name, price, imageSrc, quantity, note }]
  cartItems = [];
  isCartOpen = false;
  toastMessage = "";
  toastVariant = "success"; // success | error
  toastTimeout;

  // Đặt hàng
  isConfirmOpen = false;
  isSubmitting = false;

  // Bàn lấy từ URL (?tableId=03): tableId (Id bản ghi) dùng khi đặt hàng
  tableNumber;
  tableId;
  isTableInvalid = false;

  connectedCallback() {
    this.cartItems = this.loadCart();
    // Bind một lần để add/remove listener đúng tham chiếu
    this.handleDocumentClick = this.handleDocumentClick.bind(this);
    this.handleDocumentKeydown = this.handleDocumentKeydown.bind(this);
    document.addEventListener("click", this.handleDocumentClick);
    document.addEventListener("keydown", this.handleDocumentKeydown);
  }

  disconnectedCallback() {
    clearTimeout(this.searchTimeout);
    clearTimeout(this.toastTimeout);
    document.removeEventListener("click", this.handleDocumentClick);
    document.removeEventListener("keydown", this.handleDocumentKeydown);
  }

  // 0) Đọc số bàn trên URL rồi tra Id của Table__c theo Name (Table-03)
  @wire(CurrentPageReference)
  wiredPageRef(pageRef) {
    const rawNumber = (pageRef?.state?.tableId || "").trim();
    if (rawNumber === this.tableNumber) {
      return;
    }
    this.tableNumber = rawNumber;
    this.resolveTableId(rawNumber);
  }

  async resolveTableId(tableNumber) {
    this.tableId = undefined;
    if (!TABLE_NUMBER_PATTERN.test(tableNumber)) {
      this.isTableInvalid = true;
      return;
    }

    try {
      const tableId = await getTableIdByNumber({ tableNumber });
      // Bỏ qua kết quả cũ nếu URL đã đổi trong lúc chờ Apex
      if (tableNumber !== this.tableNumber) {
        return;
      }
      this.tableId = tableId || undefined;
      this.isTableInvalid = !tableId;
    } catch (error) {
      this.isTableInvalid = true;
      console.error("Không lấy được thông tin bàn", error);
    }
  }

  // 1) Lấy giá trị picklist Category__c từ Apex (MenuController.getCategoryOptions)
  @wire(getCategoryOptions)
  wiredCategoryOptions({ data, error }) {
    if (data) {
      // data: ["Appertizer", "Main Course", ...] (API value của picklist)
      this.categoryOptions = [
        { label: "All", value: "All" },
        ...data.map((value) => ({ label: value, value }))
      ];
    } else if (error) {
      this.categoryOptions = [];
      console.error("Không lấy được danh sách category", error);
    }
  }

  //2) Tạo dữ liệu hiển thị cho từng chip từ categoryOptions
  get categoryChips() {
    return this.categoryOptions.map((option) => {
      const isActive = option.value === this.selectedCategory;
      return {
        ...option,
        className: isActive ? "chip chip--active" : "chip",
        ariaPressed: isActive ? "true" : "false"
      };
    });
  }

  //3) Lấy dữ liệu hiển thị dựa trên category được chọn
  @wire(getMenuItems)
  menuItemsWire(result) {
    if (result.data) {
      this.allMenuItems = result.data;
    } else if (result.error) {
      this.allMenuItems = [];
      this.error = result.error;
    }
  }

  // 4) Lọc theo category đang chọn VÀ từ khóa tìm kiếm (theo Name)
  get filteredItems() {
    const items = this.allMenuItems.filter((i) => {
      const matchCategory =
        this.selectedCategory === "All" ||
        i.Category__c === this.selectedCategory;
      const matchSearch =
        !this.searchKey || normalizeText(i.Name).includes(this.searchKey);
      return matchCategory && matchSearch;
    });

    return items.map((i) => ({
      ...i,
      priceLabel: formatPrice(i.Price__c),
      imageSrc: this.buildImageSrc(i)
    }));
  }

  get hasNoResults() {
    return this.allMenuItems.length > 0 && this.filteredItems.length === 0;
  }

  buildImageSrc(menuItem) {
    return menuItem.Image_URL__c
      ? `${FOOD_IMAGES}/${FOLDER}/${menuItem.Image_URL__c}`
      : undefined;
  }

  handleCategoryClick(event) {
    this.selectedCategory = event.currentTarget.dataset.value;
  }

  // Debounce: chỉ lọc sau khi người dùng ngừng gõ SEARCH_DELAY_MS
  handleSearchChange(event) {
    const value = event.target.value;
    clearTimeout(this.searchTimeout);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.searchTimeout = setTimeout(() => {
      this.searchKey = normalizeText(value);
    }, SEARCH_DELAY_MS);
  }

  // ---------- 5) Giỏ hàng ----------
  get cartCount() {
    return this.cartItems.reduce((sum, item) => sum + item.quantity, 0);
  }

  get hasCartItems() {
    return this.cartCount > 0;
  }

  get cartAriaLabel() {
    return `Giỏ hàng, ${this.cartCount} món`;
  }

  get cartExpanded() {
    return this.isCartOpen ? "true" : "false";
  }

  handleAddToCart(event) {
    const id = event.currentTarget.dataset.id;
    const menuItem = this.allMenuItems.find((i) => i.Id === id);
    if (!menuItem) {
      return;
    }

    const existing = this.cartItems.find((item) => item.id === id);
    if (existing) {
      this.setQuantity(id, existing.quantity + 1);
    } else {
      this.updateCart([
        ...this.cartItems,
        {
          id,
          name: menuItem.Name,
          price: Number(menuItem.Price__c) || 0,
          imageSrc: this.buildImageSrc(menuItem),
          quantity: 1
        }
      ]);
    }
    this.showToast(`Đã thêm ${menuItem.Name} vào giỏ`);
  }

  handleCartToggle() {
    this.isCartOpen = !this.isCartOpen;
  }

  // Click bên trong vùng giỏ hàng không được tính là "click ra ngoài"
  handleCartAreaClick(event) {
    event.stopPropagation();
  }

  handleDocumentClick() {
    this.isCartOpen = false;
  }

  handleDocumentKeydown(event) {
    if (event.key !== "Escape") {
      return;
    }
    if (this.isConfirmOpen) {
      this.handleCancelOrder();
    } else if (this.isCartOpen) {
      this.isCartOpen = false;
    }
  }

  handleNoteChange(event) {
    const { id, note } = event.detail;
    this.updateCart(
      this.cartItems.map((item) => {
        return item.id === id
          ? { ...item, note: (note || "").slice(0, NOTE_MAX_LENGTH) }
          : item;
      })
    );
  }

  handleQuantityChange(event) {
    const { id, quantity } = event.detail;
    this.setQuantity(id, quantity);
  }

  // Số lượng <= 0 thì xóa món khỏi giỏ
  setQuantity(id, quantity) {
    if (quantity <= 0) {
      this.updateCart(this.cartItems.filter((item) => item.id !== id));
      return;
    }
    this.updateCart(
      this.cartItems.map((item) => {
        return item.id === id ? { ...item, quantity } : item;
      })
    );
  }

  handleRemoveItem(event) {
    const { id } = event.detail;
    this.updateCart(this.cartItems.filter((item) => item.id !== id));
  }

  handleClearCart() {
    this.updateCart([]);
  }

  updateCart(items) {
    this.cartItems = items;
    this.saveCart(items);
  }

  // sessionStorage: giữ giỏ khi reload, mất khi đóng tab
  loadCart() {
    try {
      const raw = sessionStorage.getItem(CART_STORAGE_KEY);
      const parsed = raw ? JSON.parse(raw) : [];
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  saveCart(items) {
    try {
      sessionStorage.setItem(CART_STORAGE_KEY, JSON.stringify(items));
    } catch {
      // Trình duyệt chặn storage: giỏ vẫn hoạt động trong phiên hiện tại
    }
  }

  // ---------- 6) Đặt hàng ----------
  get canOrder() {
    return !!this.tableId;
  }

  get cartTotalLabel() {
    const total = this.cartItems.reduce(
      (sum, item) => sum + item.price * item.quantity,
      0
    );
    return formatPrice(total);
  }

  get confirmSubmitLabel() {
    return this.isSubmitting ? "Đang gửi..." : "Xác nhận đặt hàng";
  }

  // Bước 1: bấm "Đặt hàng" trong giỏ -> mở hộp xác nhận
  handlePlaceOrderRequest() {
    if (!this.canOrder || !this.hasCartItems || this.isSubmitting) {
      return;
    }
    this.isCartOpen = false;
    this.isConfirmOpen = true;
  }

  handleCancelOrder() {
    if (!this.isSubmitting) {
      this.isConfirmOpen = false;
    }
  }

  // Click trong hộp xác nhận không được đóng hộp (chỉ click nền mới đóng)
  handleConfirmDialogClick(event) {
    event.stopPropagation();
  }

  // Bước 2: xác nhận -> gọi OrderService.placeOrder
  async handleConfirmOrder() {
    if (this.isSubmitting) {
      return;
    }
    this.isSubmitting = true;

    const orderItems = this.cartItems.map((item) => ({
      menuItemId: item.id,
      quantity: item.quantity,
      specialInstructions: item.note ? item.note.trim() : null
    }));

    try {
      console.log("Đặt hàng", this.tableId, orderItems);
      await placeOrder({ tableId: this.tableId, orderItems });
      this.updateCart([]);
      this.isConfirmOpen = false;
      this.showToast("Đặt hàng thành công!");
    } catch (error) {
      console.log("Đặt hàng thất bại", error);
      // Giữ nguyên giỏ để khách sửa rồi gửi lại
      this.isConfirmOpen = false;
      this.showToast(this.getErrorMessage(error), "error");
    } finally {
      this.isSubmitting = false;
    }
  }

  getErrorMessage(error) {
    return error?.body?.message || DEFAULT_ORDER_ERROR;
  }

  // ---------- 7) Thông báo nhỏ ----------
  get hasToast() {
    return !!this.toastMessage;
  }

  get toastClass() {
    return this.toastVariant === "error" ? "toast toast--error" : "toast";
  }

  get toastRole() {
    return this.toastVariant === "error" ? "alert" : "status";
  }

  showToast(message, variant = "success") {
    this.toastMessage = message;
    this.toastVariant = variant;
    clearTimeout(this.toastTimeout);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.toastTimeout = setTimeout(
      () => {
        this.toastMessage = "";
      },
      variant === "error" ? ERROR_TOAST_DURATION_MS : TOAST_DURATION_MS
    );
  }
}
