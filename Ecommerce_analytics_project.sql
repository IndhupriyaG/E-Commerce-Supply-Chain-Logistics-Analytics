-- ============================================================
-- BUSINESS ANALYST PORTFOLIO PROJECT USING MySQL
-- E-Commerce Supply Chain & Logistics Analytics
-- ============================================================

-- ============================================================
-- 1. BUYER ORDER FULFILLMENT & DELIVERY PERFORMANCE
-- ============================================================

-- 1.1 On-Time Delivery Rate (OTDR) - Overall & by Region & by seller
-- Definition of OTDR: Amazon calculates On-Time Delivery Rate (OTDR) by dividing the number of tracked seller-fulfilled packages delivered on or before the promised date by the total number of packages with valid tracking. 
select 
    cf.feedback_category, 
    p.category as product_category, 
    s.carrier, 
    sel.seller_id, 
    dp.partner_name, 
    COUNT(*) as complaint_count, 
    ROUND(avg(cf.rating), 2) as avg_rating 
from customer_feedback cf 
join orders o on cf.order_id = o.order_id 
join sellers sel on sel.seller_id = o.seller_id  
join products p on o.product_id = p.product_id 
join shipments s on o.order_id = s.order_id 
join last_mile_deliveries lmd on s.shipment_id = lmd.shipment_id 
join delivery_partners dp on lmd.partner_id = dp.partner_id 
where cf.rating <= 2 
group by sel.seller_id, cf.feedback_category, p.category, s.carrier, dp.partner_name 
order by complaint_count desc 
limit 10;

-- 1.2 Total number of orders missed the actual delivery date
select fc_id,
    coalesce(SUM(case when actual_delivery_date > promised_delivery_date then 1
                when actual_delivery_date is null and current_date > promised_delivery_date then 1
                else 0 end), 0) as missed_or_delayed_orders
from orders
group by fc_id
order by missed_or_delayed_orders desc;

-- 1.3 Average Delivery Delay (in days) by Carrier using CTE
with shipment_delays as (    
    select 
        s.carrier,
        o.order_id,
        o.actual_delivery_date,
        o.promised_delivery_date,
        DATEDIFF(o.actual_delivery_date, o.promised_delivery_date) AS delay_days
    from orders o 
    join shipments s on o.order_id = s.order_id 
    where o.actual_delivery_date is not null
)
select 
    carrier, 
    COUNT(*) as total_shipments, 
    COUNT(distinct order_id) as total_unique_orders,
    ROUND(avg(delay_days), 2) as avg_delay_days, 
    MAX(delay_days) as max_delay_days, 
    SUM(case when delay_days > 0 then 1 else 0 end) as delayed_orders 
from shipment_delays
group by carrier 
order by avg_delay_days desc;

-- 1.4 First Attempt Delivery Success Rate by City
select 
    dp.city,
    COUNT(*) as total_deliveries,
    SUM(case when lmd.attempt_number = 1 and lmd.delivery_status = 'Delivered' then 1 else 0 end) as first_attempt_success,
    ROUND(SUM(case when lmd.attempt_number = 1 and lmd.delivery_status = 'Delivered' then 1 else 0 end) * 100.0 / COUNT(*), 2) as first_attempt_rate
from last_mile_deliveries lmd
join delivery_partners dp on lmd.partner_id = dp.partner_id
group by dp.city
order by first_attempt_rate;

-- 1.5 Pin Codes with Highest Delivery Failures
SELECT 
    lmd.customer_pincode,
    COUNT(*) as total_attempts,
    SUM(case when lmd.delivery_status != 'Delivered' then 1 else 0 end) as failed_attempts,
    ROUND(SUM(case when lmd.delivery_status != 'Delivered' then 1 else 0 end) * 100.0 / COUNT(*), 2) as failure_rate,
    ROUND(avg(lmd.attempt_number), 2) as avg_attempts_per_delivery
from last_mile_deliveries lmd
group by lmd.customer_pincode
order by failure_rate desc
limit 100;

-- 1.6 End-to-End Order Cycle Time Breakdown
select 
o.order_id,
datediff(s.dispatch_time, o.order_date) as processing_days,
datediff(s.arrival_time, s.dispatch_time) as transit_days,
datediff(lmd.delivery_timestamp,s.arrival_time) as last_mile_days,
datediff(lmd.delivery_timestamp,o.order_date) as total_cycle_days
from orders o
join shipments s on o.order_id = s.order_id
join last_mile_deliveries lmd on s.shipment_id = lmd.shipment_id
where lmd.delivery_status = 'Delivered'
  and lmd.attempt_number = (
      select max(attempt_number) 
      from last_mile_deliveries 
      where shipment_id = lmd.shipment_id and delivery_status = 'Delivered'
  );

-- 1.7 Highly ranked carrier
select 
    dp.partner_id, 
    dp.partner_name,
    count(o.order_id) as total_deliveries,
    -- Calculates the average days delayed across all shipments
    avg(datediff(o.actual_delivery_date, o.promised_delivery_date)) as avg_delay_days,
    -- Calculates the percentage of orders delivered on time or early
    sum(case when datediff(o.actual_delivery_date, o.promised_delivery_date) <= 0 then 1 else 0 end) * 100.0 / count(o.order_id) as on_time_percentage,
    -- Ranks carriers starting with the lowest average delay
    rank() over (order by avg(datediff(o.actual_delivery_date, o.promised_delivery_date)) asc) as carrier_performance_rank
from orders o 
join shipments s on s.order_id = o.order_id 
join last_mile_deliveries lmd on s.shipment_id = lmd.shipment_id 
join delivery_partners dp on lmd.partner_id = dp.partner_id 
where o.actual_delivery_date is not null
group by dp.partner_id, dp.partner_name
order by carrier_performance_rank;

-- ============================================================
-- 2. INVENTORY & WAREHOUSE OPTIMIZATION
-- ============================================================

-- 2.1 Stockout Risk - Products Below Reorder Level
select 
    p.product_name,
    fc.fc_code,
    fc.city,
    i.quantity_available,
    i.quantity_reserved,
    i.reorder_level,
    (i.quantity_available - i.quantity_reserved) as net_available,
    case 
        when (i.quantity_available - i.quantity_reserved) <= 0 then 'CRITICAL - Out of Stock'
        when (i.quantity_available - i.quantity_reserved) <= i.reorder_level then 'WARNING - Below Reorder Level'
        else 'OK'
    end as stock_status
from inventory i
join products p on i.product_id = p.product_id
join fulfillment_centers fc on i.fc_id = fc.fc_id
where (i.quantity_available - i.quantity_reserved) <= i.reorder_level
order by net_available;

-- 2.2 Fulfillment Center Capacity Utilization
select 
    fc.fc_code,
    fc.city,
    fc.region,
    fc.fc_type,
    fc.capacity_units,
    coalesce(sum(i.quantity_available), 0) as total_inventory_held,
    round(coalesce(SUM(i.quantity_available), 0) * 100.0 / fc.capacity_units, 2) as utilization_percentage,
    case 
        when coalesce(SUM(i.quantity_available), 0) * 100.0 / fc.capacity_units > 90 then 'Over-utilized'
        when coalesce(SUM(i.quantity_available), 0) * 100.0 / fc.capacity_units > 70 then 'Optimal'
        when coalesce(SUM(i.quantity_available), 0) * 100.0 / fc.capacity_units > 40 then 'Under-utilized'
        else 'Severely Under-utilized'
    end as utilization_status
from fulfillment_centers fc
left join inventory i on fc.fc_id = i.fc_id
group by fc.fc_id, fc.fc_code, fc.city, fc.region, fc.fc_type, fc.capacity_units
order by utilization_percentage desc;

-- 2.3 Inventory Turnover Rate by Product Category
select 
    p.category,
    SUM(i.quantity_available) as avg_inventory,
    COUNT(o.order_id) as units_sold,
    ROUND(COUNT(o.order_id) * 1.0 / NULLIF(SUM(i.quantity_available), 0), 2) as turnover_ratio,
    case 
        when ROUND(COUNT(o.order_id) * 1.0 / NULLIF(SUM(i.quantity_available), 0), 2) > 5 then 'Fast Moving'
        when ROUND(COUNT(o.order_id) * 1.0 / NULLIF(SUM(i.quantity_available), 0), 2) > 2 then 'Moderate'
        else 'Slow Moving'
    end as movement_category
from products p
join inventory i on p.product_id = i.product_id
left join orders o on p.product_id = o.product_id
group by p.category
order by turnover_ratio desc;

-- 2.4 Dead Stock Identification (High Inventory, Zero/Low Orders)
select 
    p.product_id,
    p.product_name,
    p.category,
    sum(i.quantity_available) as total_stock,
    count(o.order_id) as total_orders,
    round(p.price * sum(i.quantity_available), 2) as blocked_capital
from products p
join inventory i on p.product_id = i.product_id
left join orders o on p.product_id = o.product_id
group by p.product_id, p.product_name, p.category, p.price
order by blocked_capital desc;

-- ============================================================
-- 3. CUSTOMER FEEDBACK & SATISFACTION
-- ============================================================
-- 3.1 Rating Distribution by Feedback Category
select 
    cf.feedback_category,
    count(*) as total_feedback,
    round(avg(cf.rating), 2) as avg_rating
    from customer_feedback cf
group by cf.feedback_category;

-- 3.2 Correlation: Late Delivery vs Low Ratings
select 
    count(*) as total_orders,
    case 
        when datediff(o.actual_delivery_date, o.promised_delivery_date) <= 0 then 'On Time'
        when datediff(o.actual_delivery_date, o.promised_delivery_date) between 1 and 3 then 'Delayed 1-3 Days'
        when datediff(o.actual_delivery_date, o.promised_delivery_date) between 4 and 7 then 'Delayed 4-7 Days'
        else 'Delayed 7+ Days'
    end as delay_bucket,
    round(avg(cf.rating), 2) as avg_rating,
    sum(case when cf.rating <= 2 then 1 else 0 end) as low_rating_count,
    round(sum(case when cf.rating <= 2 then 1 else 0 end) * 100.0 / count(*), 2) as low_rating_pct
from orders o
join customer_feedback cf on o.order_id = cf.order_id
where o.actual_delivery_date is not null
group by delay_bucket
order by low_rating_pct desc;

-- 3.3 Monthly Feedback Trend with (Net Promoter Score) Proxy
select 
    date_format(cf.feedback_date, '%Y-%m') as month,
    count(cf.rating) as total_feedback,
    round(avg(cf.rating), 2) as avg_rating,
    round(
        (sum(case when cf.rating >= 4 then 1 else 0 end) - 
         sum(case when cf.rating <= 2 then 1 else 0 end)) * 100.0 / count(cf.rating), 2) as nps_proxy
from customer_feedback cf
group by month
order by month;

-- Most ordered product
create procedure most_ordered_product()
    select o.product_id,
    p.product_name    
    from orders o
    join products p on o.product_id = p.product_id
    group by product_id
    order by count(*) desc
    limit 2;
call most_ordered_product();

-- 3.4 Top 10 Negative Feedback Drivers (Low-Rated Orders Analysis)
select 
    cf.feedback_category,
    p.category as product_category,
    s.carrier,
    dp.partner_name,
    count(*) as complaint_count,
    round(avg(cf.rating), 2) as avg_rating
from customer_feedback cf
join orders o on cf.order_id = o.order_id
join products p on o.product_id = p.product_id
join shipments s on o.order_id = s.order_id
join last_mile_deliveries lmd on s.shipment_id = lmd.shipment_id
join delivery_partners dp on lmd.partner_id = dp.partner_id
where cf.rating <= 2
group by cf.feedback_category, p.category, s.carrier, dp.partner_name
order by complaint_count desc
limit 10;

-- 3.5 Most number of orders in a month 
create temporary table MonthlyOrderCounts as
select 
    date_format(order_date, '%Y-%m') as order_month,
    COUNT(order_id) as total_orders
from orders
group by date_format(order_date, '%Y-%m');
-- query to execute the temporary table
SELECT 
    order_month, 
    total_orders
from MonthlyOrderCounts
order by total_orders desc
limit 1;

-- ============================================================
-- 4. PAYMENT & REVENUE ANALYSIS
-- ============================================================
-- 4.1 Payment Settlement Cycle Analysis
select 
    pay.payment_method,
    count(*) as total_payments,
    round(avg(datediff(pay.settlement_date, pay.payment_date)), 2) as avg_settlement_days,
    min(datediff(pay.settlement_date,pay.payment_date)) as min_settlement_days,
    max(datediff(pay.settlement_date, pay.payment_date)) as max_settlement_days
from payments pay
where pay.settlement_date is not null pay.payment_status = 'Completed'
group by pay.payment_method
order by avg_settlement_days desc;

-- 4.2 Payment Failure Analysis
select 
    pay.payment_method,
    pay.payment_status,
    count(*) as count,
    round(sum(pay.payment_amount), 2) as total_amount_affected,
    round(count(*) * 100.0 / sum(count(*)) over (partition by pay.payment_method), 2) as failure_rate_by_method
from payments pay
group by pay.payment_method, pay.payment_status
order by pay.payment_method, pay.payment_status;

-- 4.3 Revenue by Category - Monthly Trend
select 
    date_format(o.order_date, '%Y-%m') as month,
    p.category,
    count(o.order_id) as order_count,
    round(sum(o.order_value), 2) as total_revenue,
    round(avg(o.order_value), 2) as avg_order_value
from orders o
join products p on o.product_id = p.product_id
group by date_format(o.order_date, '%Y-%m'), p.category
order by month, total_revenue desc;

-- ============================================================
-- 5. SUPPLY CHAIN & LOGISTICS EFFICIENCY
-- ============================================================

-- 5.1 Carrier Cost Efficiency Analysis
select 
    s.carrier,
    count(*) as total_shipments,
    round(avg(s.cost), 2) as avg_cost,
    round(avg(s.distance_km), 2) as avg_distance_km,
    round(avg(s.cost / nullif(s.distance_km, 0)), 2) as cost_per_km,
    round(avg(datediff(s.arrival_time, s.dispatch_time)) * 24, 2) as avg_transit_hours,
    round(avg(s.cost / nullif(datediff(s.arrival_time, s.dispatch_time), 0)), 2) as cost_per_day
from shipments s
group by s.carrier
order by cost_per_km;

-- 5.2 Carrier Performance Benchmarking (Transit + Delivery Success)
select 
    dp.partner_id, 
    dp.partner_name, 
    count(o.order_id) as total_deliveries, 
    -- Calculates the average days delayed across all shipments 
    round(avg(datediff(o.actual_delivery_date, o.promised_delivery_date)), 2) as avg_delay_days, 
    -- Calculates the percentage of orders delivered on time or early 
    round((sum(case when datediff(o.actual_delivery_date, o.promised_delivery_date) <= 0 then 1 else 0 end) * 100.0 / COUNT(o.order_id)), 2) as on_time_percentage, 
    -- Ranks carriers starting with the lowest average delay 
    rank() over (order by avg (datediff(o.actual_delivery_date, o.promised_delivery_date)) asc) as carrier_performance_rank 
from orders o 
join shipments s on s.order_id = o.order_id 
join last_mile_deliveries lmd on s.shipment_id = lmd.shipment_id 
join delivery_partners dp on lmd.partner_id = dp.partner_id 
where o.actual_delivery_date is not null 
group by dp.partner_id, dp.partner_name 
order by carrier_performance_rank;

-- 5.3 Hub-Level Bottleneck Analysis
select 
    s.destination_hub,
    count(*) as total_shipments,
    round(avg(datediff(s.arrival_time,s.dispatch_time)) * 24, 2) as avg_transit_hours,
    round(avg(s.cost), 2) as avg_cost,
    sum(case when o.actual_delivery_date > o.promised_delivery_date then 1 else 0 end) as delayed_orders,
    round(sum(case when o.actual_delivery_date > o.promised_delivery_date then 1 else 0 end) * 100.0 / COUNT(*), 2) as delay_rate
from shipments s
join orders o on s.order_id = o.order_id
where o.actual_delivery_date is not null
group by s.destination_hub
order by delay_rate desc;

-- 5.4 FC-to-Hub Route Efficiency Matrix
select 
    fc.fc_code as origin_fc,
    s.destination_hub,
    count(*)as shipment_count,
    round(avg(s.distance_km), 2) as avg_distance,
    round(avg(s.cost), 2) as avg_cost,
    round(avg(datediff(s.arrival_time,s.dispatch_time)) * 24, 2) as avg_transit_hours,
    round(avg(s.cost / NULLIF(s.distance_km, 0)), 4) as cost_per_km
from shipments s
join fulfillment_centers fc on s.origin_fc_id = fc.fc_id
group by fc.fc_code, s.destination_hub
having count(*) >= 3
order by cost_per_km desc;

-- 5.5 Delivery Partner Performance Ranking
select 
    dp.partner_name,
    dp.partner_type,
    dp.city,
    dp.active_drivers,
    dp.avg_delivery_rating,
    count(lmd.delivery_id) as total_deliveries,
    sum(case when lmd.delivery_status = 'Delivered' then 1 else 0 end) as successful_deliveries,
    round(sum(case when  lmd.delivery_status = 'Delivered' then 1 else 0 end) * 100.0 / count(*), 2) as success_rate,
    round(avg(lmd.attempt_number), 2) as avg_attempts
from delivery_partners dp
join last_mile_deliveries lmd on dp.partner_id = lmd.partner_id
group by dp.partner_id, dp.partner_name, dp.partner_type, dp.city, dp.active_drivers, dp.avg_delivery_rating
order by success_rate desc;
