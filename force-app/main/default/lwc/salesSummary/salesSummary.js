/**
 * SalesSummary (LWC)
 * ------------------
 * Purpose
 *  - Fetch and display a 12-month sales summary for a selected Sales Rep (User).
 *  - Keep UI responsive with a spinner, show a clear "no data" message when applicable,
 *    and color months with zero sales in red.
 *
 * Data flow
 *  - connectedCallback(): retrieves active users and preselects the current user, but does NOT auto-load data.
 *  - User clicks "Show Summary" → loadData() calls Apex and renders the table.
 *
 * UX contract
 *  - Spinner (isLoading) is shown only while a server call is in progress.
 *  - Inline "No sales..." text appears only after the first completed query (queriedOnce = true).
 *  - Table is hidden while loading and when there are no rows to show.
 *
 * Performance & correctness
 *  - Uses a single imperative Apex call per click; finally{} guarantees spinner cleanup.
 *  - Columns are predeclared; red styling for zeros is applied via SLDS utility classes.
 *
 * Security
 *  - CRUD/FLS checks are enforced in Apex. This component surfaces friendly toasts on failures.
 *
 * Extensibility
 *  - If you later add CDC/refresh logic, call loadData() (or refreshApex if you switch to @wire)
 *    after a change event to keep the grid in sync without a page refresh.
 */
import { LightningElement, track } from 'lwc';
import getMonthlyTotals from '@salesforce/apex/SalesSummaryController.getMonthlyTotals';
import getActiveUsers from '@salesforce/apex/SalesSummaryController.getActiveUsers';
import USER_ID from '@salesforce/user/Id';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class SalesSummary extends LightningElement {
    // ---- reactive UI state ----
    @track userOptions = [];     // combobox options: [{ label: string, value: Id }]
    selectedUserId = null;       // currently selected sales rep (User Id)
    rows = [];                   // datatable rows derived from Apex result
    queriedOnce = false;         // becomes true after the first completed query (controls inline "no data" message)
    isLoading = false;           // spinner flag; managed centrally in loadData()

    // ---- datatable schema ----
    columns = [
        { label: 'Month', fieldName: 'monthLabel', type: 'text' },
        {
            label: 'Amount',
            fieldName: 'amountDisplay',
            type: 'text',
            cellAttributes: { class: { fieldName: 'amountClass' } } // red + bold when amount is zero
        }
    ];

    // Load user list and preselect the current user (no data query yet to avoid implicit calls)
    async connectedCallback() {
        try {
            const opts = await getActiveUsers();
            this.userOptions = opts || [];
            const hasCurrent = this.userOptions.some(o => o.value === USER_ID);
            this.selectedUserId = hasCurrent ? USER_ID : (this.userOptions[0]?.value ?? null);
        } catch (e) {
            this.toast('Error', this.errMsg(e, 'Failed to load users.'), 'error');
        }
    }

    // ---- derived UI flags (template bindings) ----
    get isLoadDisabled() {
        return !this.selectedUserId; // prevent calls when no user is selected
    }
    get actionDisabled() {
        return this.isLoading || this.isLoadDisabled; // disable buttons while loading or invalid
    }
    get hasTable() {
        return !this.isLoading && this.rows.length > 0; // hide grid during load and when empty
    }
    get showInlineNoData() {
        // show inline message only after at least one completed query that produced no rows
        return !this.isLoading && this.queriedOnce && !this.hasTable;
    }

    // Update selection; clear previous results and hide the inline message until next query completes
    handleRepChange(event) {
        this.selectedUserId = event.detail.value;
        this.rows = [];
        this.queriedOnce = false;
    }

    // Primary action entry points (both buttons funnel into the same loader)
    async handleLoadClick() {
        await this.loadData();
    }
    async handleRefreshClick() {
        await this.loadData();
    }

    /**
     * Fetch and render the 12-month series for the selected sales rep.
     * Guarantees spinner cleanup via finally{} even on early returns or thrown errors.
     */
    async loadData() {
        if (!this.selectedUserId) return;

        this.rows = [];
        this.isLoading = true;
        try {
            const result = await getMonthlyTotals({ salesRepId: this.selectedUserId });
            const points = (result && result.points) ? result.points : [];
            this.queriedOnce = true;

            // No data returned for the entire window → toast + keep grid hidden
            if (!points.length) {
                this.toast('No Data', 'No sales found for the selected sales rep.', 'warning');
                return;
            }

            // Map DTO → datatable rows; mark zero totals visually
            const tableRows = points.map(p => {
                const isZero = !p.total || Number(p.total) === 0;
                return {
                    monthLabel: this.formatMonth(p.year, p.month),
                    amountDisplay: this.formatCurrency(p.total),
                    amountClass: isZero ? 'slds-text-color_error slds-text-title_bold' : ''
                };
            });

            // If all months are zero, treat as “no data” for UX clarity
            const anyNonZero = tableRows.some(r => !r.amountClass);
            if (!anyNonZero) {
                this.toast('No Data', 'No sales found for the selected sales rep.', 'warning');
                this.rows = [];
                return;
            }

            this.rows = tableRows;
        } catch (e) {
            this.queriedOnce = true; // allows inline error state if needed
            this.toast('Error', this.errMsg(e, 'Failed to load data.'), 'error');
        } finally {
            this.isLoading = false; // always end spinner
        }
    }

    // ---- formatting helpers ----
    formatMonth(year, monthNum) {
        const m = monthNum < 10 ? `0${monthNum}` : `${monthNum}`;
        return `${year}-${m}`;
    }
    formatCurrency(amount) {
        try {
            return new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD' }).format(amount || 0);
        } catch {
            return `${amount}`;
        }
    }

    // ---- toast/error helpers ----
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    errMsg(e, fallback) {
        return e && e.body && e.body.message ? e.body.message : fallback;
    }
}
