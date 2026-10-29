import { createElement } from "@lwc/engine-dom";
import MenuPageComponent from "c/menuPageComponent";
import getMenuItems from "@salesforce/apex/MenuController.getMenuItems";
import getCategoryOptions from "@salesforce/apex/MenuController.getCategoryOptions";

// Mock the Apex methods as wire adapters so tests can emit data/errors
jest.mock(
  "@salesforce/apex/MenuController.getMenuItems",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/MenuController.getCategoryOptions",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);

const MENU_ITEMS = [
  { Id: "a01000000000001AAA", Name: "Phở bò tái", Price__c: 50000 },
  { Id: "a01000000000002AAA", Name: "Bún chả", Price__c: 45000 }
];

const CATEGORY_OPTIONS = ["Appertizer", "Main Course", "Dessert", "Beverage"];

// Wait for LWC to re-render after a state change
const flushPromises = () => Promise.resolve();

const getChips = (element) => [
  ...element.shadowRoot.querySelectorAll(".toolbar__chips button")
];

const getActiveChips = (element) =>
  getChips(element).filter((c) => c.getAttribute("aria-pressed") === "true");

describe("c-menu-page-component", () => {
  let element;

  beforeEach(() => {
    element = createElement("c-menu-page-component", {
      is: MenuPageComponent
    });
    element.title = "Menu";
    document.body.appendChild(element);
  });

  afterEach(() => {
    // The jsdom instance is shared across test cases in a single file so reset the DOM
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("renders the title passed through the @api property", () => {
    expect(element.shadowRoot.querySelector("h1").textContent).toBe("Menu");
  });

  it("renders no chips before category options arrive", () => {
    expect(getChips(element)).toHaveLength(0);
  });

  it('renders "All" plus one chip per category option, with only "All" active', async () => {
    getCategoryOptions.emit(CATEGORY_OPTIONS);
    await flushPromises();

    const chips = getChips(element);
    expect(chips.map((c) => c.textContent.trim())).toEqual([
      "All",
      "Appertizer",
      "Main Course",
      "Dessert",
      "Beverage"
    ]);
    chips.forEach((c) => expect(c.getAttribute("type")).toBe("button"));

    const active = getActiveChips(element);
    expect(active).toHaveLength(1);
    expect(active[0].textContent.trim()).toBe("All");
    expect(active[0].className).toBe("chip chip--active");
  });

  it("sets data-value on each chip to the category API value", async () => {
    getCategoryOptions.emit(CATEGORY_OPTIONS);
    await flushPromises();

    expect(getChips(element).map((c) => c.dataset.value)).toEqual([
      "All",
      "Appertizer",
      "Main Course",
      "Dessert",
      "Beverage"
    ]);
  });

  it("moves the active state to the clicked chip", async () => {
    getCategoryOptions.emit(CATEGORY_OPTIONS);
    await flushPromises();

    getChips(element)[2].click(); // "Main Course"
    await flushPromises();

    const chips = getChips(element);
    const active = getActiveChips(element);
    expect(active).toHaveLength(1);
    expect(active[0].textContent.trim()).toBe("Main Course");
    expect(active[0].classList.contains("chip--active")).toBe(true);

    const allChip = chips[0];
    expect(allChip.getAttribute("aria-pressed")).toBe("false");
    expect(allChip.className).toBe("chip");
  });

  it('can switch back to "All" after selecting another chip', async () => {
    getCategoryOptions.emit(CATEGORY_OPTIONS);
    await flushPromises();

    getChips(element)[4].click(); // "Beverage"
    await flushPromises();
    getChips(element)[0].click(); // "All"
    await flushPromises();

    const active = getActiveChips(element);
    expect(active).toHaveLength(1);
    expect(active[0].textContent.trim()).toBe("All");
  });

  it("logs the error and renders no chips when the category options wire fails", async () => {
    const consoleError = jest
      .spyOn(console, "error")
      .mockImplementation(() => {});

    getCategoryOptions.error();
    await flushPromises();

    expect(consoleError).toHaveBeenCalled();
    expect(getChips(element)).toHaveLength(0);
    consoleError.mockRestore();
  });

  it("renders an accessible cart button with a badge", () => {
    const cart = element.shadowRoot.querySelector("button.cart-button");
    expect(cart.getAttribute("aria-label")).toBe("Cart");
    expect(cart.querySelector(".cart-button__badge").textContent).toBe("2");
  });

  it("renders an accessible search input", () => {
    const input = element.shadowRoot.querySelector("input.search__input");
    expect(input.getAttribute("type")).toBe("text");
    expect(input.getAttribute("placeholder")).toBe("Search for food...");
    expect(input.getAttribute("aria-label")).toBe("Search for food");
  });

  it("renders no dish cards before menu items arrive", () => {
    expect(
      element.shadowRoot.querySelectorAll("article.dish-card")
    ).toHaveLength(0);
  });

  it("renders one dish card per menu item returned by Apex", async () => {
    getMenuItems.emit(MENU_ITEMS);
    await flushPromises();

    const cards = [...element.shadowRoot.querySelectorAll("article.dish-card")];
    expect(cards).toHaveLength(2);
    expect(
      cards.map((c) => c.querySelector(".dish-card__name").textContent)
    ).toEqual(["Phở bò tái", "Bún chả"]);
    expect(cards[0].querySelector(".dish-card__price").textContent).toBe(
      "50000"
    );
  });

  it("renders no dish cards when the Apex wire fails", async () => {
    getMenuItems.emit(MENU_ITEMS);
    await flushPromises();
    getMenuItems.error();
    await flushPromises();

    expect(
      element.shadowRoot.querySelectorAll("article.dish-card")
    ).toHaveLength(0);
  });
});
